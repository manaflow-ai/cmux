public import CmuxNextCloud
public import Foundation
import os

/// Whether a Cloud start's agent can run on the new machine it is about to make, asked right before that machine
/// is made (red 1 of the Cloud composer journey, 2026-11-10: a start leased a machine, then its Claude answered
/// "You've hit your weekly limit · resets Nov 14, 1pm (UTC)", so every start paid for a machine it could not use).
/// The composer's Cloud send (``newMachineRefusal(harness:model:login:userID:teamID:otherTeams:dogfood:)`` before
/// its create) and `cloud start-session` (`cmux chat --on vm:new`, `cmux cloud start-chat`, before its create) ask
/// it; a start onto a machine that already exists is never asked, since that machine may keep a login of its own.
///
/// One prediction, then up to one ask: the harness login rules' verdict for the new machine (the person's own, on an
/// owner guest, with no login of its own; the start's `--login`, an agent's narrowed by the person's kept choice; a
/// Release build's remote switch, unread here, counts as off), as the start itself will reach it.
/// - A start that may show no prompt gets that verdict's refusal before the machine.
/// - A verdict that installs the person's Claude login asks Anthropic once with that login (one output token) and
///   reads the reply's `anthropic-ratelimit-unified-*` headers; the rule and its words are Rust's (cmux-cloud-start-core
///   `agent_check`, app FFI `cloud_agent_check`). A used-up limit for the start's model refuses until it resets.
/// Every other start goes on: this check refuses only a start it knows cannot run.
@MainActor public final class CloudAgentCheck {
    /// The probe's whole budget: a probe that has not answered by then lets the start go on.
    nonisolated static let probeTimeout: TimeInterval = 2.5
    /// The model a probe asks when the start names no full Claude model id: the cheapest, as Claude Code's small calls.
    nonisolated static let probeModel = "claude-haiku-5-5"
    private static let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "app.cloud")

    /// The probe's reply as the rule reads it.
    struct Probe: Codable, Equatable { var status: Int; var headers: [String: String] }
    struct Request: Encodable { var harness: String?; var model: String?; var probe: Probe?; var now: Int64 }
    struct Refusal: Decodable, Equatable { var code: String; var message: String }
    struct Answer: Decodable, Equatable { var refusal: Refusal?; var freshUntil: Int64 }

    /// Why a new machine is not made.
    public enum Refused: Equatable, Sendable {
        /// The harness login rules refuse a start that may show no prompt.
        case login(CloudHarnessLoginDecision.Reason)
        /// The person's Claude limit for this model is used up: the refusal's words.
        case limit(String)

        /// ``limit(_:)``'s words; nil for a login refusal.
        public var limitWords: String? { if case .limit(let words) = self { words } else { nil } }
        /// ``login(_:)``'s reason; nil for a used-up limit.
        public var loginReason: CloudHarnessLoginDecision.Reason? { if case .login(let reason) = self { reason } else { nil } }
    }

    /// Each person's and model's last answer, while it stands (``Answer/freshUntil``): a used-up limit until it resets.
    private var kept: [String: Answer] = [:]
    /// The ask in flight per person and model: a second start while it runs waits on it instead of asking again.
    private var asking: [String: Task<Answer?, Never>] = [:]
    /// Sends the probe; tests replace it.
    var send: @Sendable (URLRequest) async throws -> (Data, URLResponse) = { try await URLSession.shared.data(for: $0) }
    /// Now, in unix seconds; tests replace it.
    var now: @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970) }
    /// The person's cached Claude login (user, team, other teams), as the start reads it; tests replace it.
    var cachedLogin: (String, String?, [String?]) async -> Data? = { userID, teamID, otherTeams in
        try? await CloudCredentialLogin.loadAny(provider: .claude, teamID: teamID, otherTeams: otherTeams, userID: userID)
    }

    public init() {}

    /// Why the new machine of a start of `harness` and `model` (nil: the harness default) should not be made; nil
    /// when it goes on, and whenever the answer is unknown (no cached login, a Keychain or a probe that did not answer).
    public func newMachineRefusal(harness: String?, model: String?, login: CloudHarnessLoginAsk, userID: String?, teamID: String?,
                                  otherTeams: [String?], dogfood: Bool) async -> Refused? {
        guard let userID else { return nil }
        var decision = CloudHarnessLoginDecision(dogfood: dogfood, setting: CloudCredentialTransfer.passHarnessLoginSetting(.standard),
                                                 harness: harness, signedIn: true)
        login.apply(to: &decision, userID: userID) // an agent's --login narrowed by the person's kept choice, as the start does
        decision.callerOwns = true
        decision.guestStdout = "vm-kind:owner\n"
        decision.machineLogin = CloudMachineLogin.none
        let ahead = decision.verdict // a Release build's switch, unread here, is off: no Keychain read, no ask
        guard ahead.transferProvider == .claude, ahead.gate else { return ahead.step == .refuse ? .login(ahead.reason) : nil }
        let token = await cachedLogin(userID, teamID, otherTeams)
        decision.cached = token != nil
        let verdict = decision.verdict
        if verdict.step == .refuse { return .login(verdict.reason) }
        // Only a verdict that installs the person's Claude login runs on it; none cached: the machine signs in on its own.
        guard verdict.step == .install || verdict.step == .confirmThenInstall, let token else { return nil }
        return await limitRefusal(harness: harness, model: model, userID: userID, token: token).map(Refused.limit)
    }

    /// The refusal's words when `token`'s Claude limit for `model` is used up; nil otherwise or when unknown.
    func limitRefusal(harness: String?, model: String?, userID: String, token: Data) async -> String? {
        let key = userID + "\n" + (model ?? "")
        if let kept = kept[key], kept.freshUntil > now() { return kept.refusal?.message }
        let task = asking[key] ?? Task { [self] in
            guard let probe = await probe(token, model: model) else { return nil }
            return Self.answer(harness: harness, model: model, probe: probe, now: now())
        }
        asking[key] = task
        let answer = await task.value
        if asking[key] == task { asking[key] = nil }
        guard let answer else { return nil }
        kept[key] = answer
        if let refusal = answer.refusal { Self.logger.info("cloud start: refused before the lease: \(refusal.code, privacy: .public)") }
        return answer.refusal?.message
    }

    /// The rule's answer for `probe` (cmux-cloud-start-core `agent_check::check`); nil when the FFI does not answer.
    nonisolated static func answer(harness: String?, model: String?, probe: Probe?, now: Int64) -> Answer? {
        CloudStartCore().call("cloud_agent_check", Request(harness: harness, model: model, probe: probe, now: now), as: Answer.self)
    }

    /// One request with `token` for one output token of `model`'s limits; its status and headers, or nil when it did not answer in time.
    private func probe(_ token: Data, model: String?) async -> Probe? {
        guard let bearer = String(data: token, encoding: .utf8), let request = Self.probeRequest(bearer: bearer, model: model) else { return nil }
        let reply = try? await send(request)
        guard let response = reply?.1 as? HTTPURLResponse else { return nil }
        return Self.probe(response)
    }

    /// The probe: Claude Code's own request shape for a subscription login, the smallest it can be, on the start's own
    /// model when it names a full Claude model id (its limits are that model's), else the cheapest.
    nonisolated static func probeRequest(bearer: String, model: String? = nil) -> URLRequest? {
        guard let url = URL(string: "https://api.anthropic.com/v1/messages") else { return nil }
        var request = URLRequest(url: url, timeoutInterval: probeTimeout)
        request.httpMethod = "POST"
        request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = ["model": model.flatMap { $0.lowercased().hasPrefix("claude-") ? $0 : nil } ?? probeModel, "max_tokens": 1, "system": "You are Claude Code, Anthropic's official CLI for Claude.",
                                   "messages": [["role": "user", "content": "ok"]]]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return request
    }

    /// A reply's status and its limit headers (only `anthropic-ratelimit-unified-*` leave this function).
    nonisolated static func probe(_ response: HTTPURLResponse) -> Probe {
        var headers: [String: String] = [:]
        for (key, value) in response.allHeaderFields {
            guard let key = (key as? String)?.lowercased(), key.hasPrefix("anthropic-ratelimit-unified-") else { continue }
            headers[key] = value as? String ?? "\(value)"
        }
        return Probe(status: response.statusCode, headers: headers)
    }
}
