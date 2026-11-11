public import CmuxNextCloud
public import Foundation
import os

/// Whether a Cloud start's agent can run, asked before any machine is made or claimed (red 1 of the Cloud
/// composer journey, 2026-11-10: a start leased a machine, then its Claude answered "You've hit your weekly
/// limit · resets Nov 14, 1pm (UTC)", so every start paid for a machine it could not use). The composer's
/// Cloud send (`CloudStartChat.run`) and `cloud start-session` (`cmux chat --on vm:new`, `cmux cloud
/// start-chat`) both ask it right before their machine step, beside the folder checks.
///
/// Two checks, each refusing only a start it knows cannot run:
/// - ``limitRefusal(harness:login:userID:teamID:otherTeams:)``: a Claude start whose machine gets the person's
///   own Claude login asks Anthropic once with that login (one token of the smallest model) and reads the
///   reply's `anthropic-ratelimit-unified-*` headers; the rule and its words are Rust's (cmux-cloud-start-core
///   `agent_check`, app FFI `cloud_agent_check`). A used-up limit refuses until it resets, with no second ask.
/// - ``loginRefusal(harness:login:userID:teamID:otherTeams:dogfood:)``: a start that may show no prompt and
///   would make a new machine gets the harness login rules' verdict for that machine first (a new machine is the
///   person's own, on an owner guest, with no login of its own), so a refusal those rules give comes before the lease.
@MainActor public final class CloudAgentCheck {
    /// The probe's whole budget: a probe that has not answered by then lets the start go on.
    nonisolated static let probeTimeout: TimeInterval = 2.5
    /// The cheapest model a Claude login may ask, as Claude Code's own small calls do.
    nonisolated static let probeModel = "claude-haiku-5-5"
    private static let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "app.cloud")

    /// The probe's reply as the rule reads it.
    struct Probe: Codable, Equatable { var status: Int; var headers: [String: String] }
    struct Request: Encodable { var harness: String?; var probe: Probe?; var now: Int64 }
    struct Refusal: Decodable, Equatable { var code: String; var message: String }
    struct Answer: Decodable, Equatable { var refusal: Refusal?; var freshUntil: Int64 }

    /// Each person's last answer, while it stands (``Answer/freshUntil``): a used-up limit until it resets.
    private var kept: [String: Answer] = [:]
    /// Sends the probe; tests replace it.
    var send: @Sendable (URLRequest) async throws -> (Data, URLResponse) = { try await URLSession.shared.data(for: $0) }
    /// Now, in unix seconds; tests replace it.
    var now: @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970) }
    /// The person's cached Claude login (user, team, other teams), as the start reads it; tests replace it.
    var cachedLogin: (String, String?, [String?]) async -> Data? = { userID, teamID, otherTeams in
        try? await CloudCredentialLogin.loadAny(provider: .claude, teamID: teamID, otherTeams: otherTeams, userID: userID)
    }

    public init() {}

    /// The refusal's words when the person's Claude limit is used up and this start's machine would get their Claude
    /// login; nil otherwise, and whenever the answer is unknown (no cached login, a Keychain or a probe that did not answer).
    public func limitRefusal(harness: String?, login: CloudHarnessLoginAsk, userID: String?, teamID: String?, otherTeams: [String?]) async -> String? {
        guard let userID, Self.passesClaudeLogin(harness: harness, login: login, userID: userID) else { return nil }
        if let kept = kept[userID], kept.freshUntil > now() { return kept.refusal?.message }
        // The login the start would copy (``CloudCredentialLogin``); none cached: the machine signs in on its own.
        guard let token = await cachedLogin(userID, teamID, otherTeams), let probe = await probe(token) else { return nil }
        guard let answer = Self.answer(harness: harness, probe: probe, now: now()) else { return nil }
        kept[userID] = answer
        if let refusal = answer.refusal { Self.logger.info("cloud start: refused before the lease: \(refusal.code, privacy: .public)") }
        return answer.refusal?.message
    }

    /// The rule's answer for `probe` (cmux-cloud-start-core `agent_check::check`); nil when the FFI does not answer.
    nonisolated static func answer(harness: String?, probe: Probe?, now: Int64) -> Answer? {
        CloudStartCore().call("cloud_agent_check", Request(harness: harness, probe: probe, now: now), as: Answer.self)
    }

    /// Whether this start's machine would get the person's Claude login: a Claude harness (the rules' own reading, so
    /// `claude-sr2` counts and none named is Claude), the copy not turned off, and no `--login` or kept choice of none or machine.
    nonisolated static func passesClaudeLogin(harness: String?, login: CloudHarnessLoginAsk, userID: String) -> Bool {
        let decision = CloudHarnessLoginDecision(dogfood: true, setting: nil, harness: harness, signedIn: true)
        guard decision.verdict.transferProvider == .claude,
              CloudCredentialTransfer.passHarnessLoginSetting(.standard) != false else { return false }
        let choice = login.requested ?? CloudHarnessLoginChoices().load(userID: userID)
        return choice != CloudHarnessLoginDecision.Choice.none && choice != .machine
    }

    /// One request with `token` for one output token; its status and headers, or nil when it did not answer in time.
    private func probe(_ token: Data) async -> Probe? {
        guard let bearer = String(data: token, encoding: .utf8), let request = Self.probeRequest(bearer: bearer) else { return nil }
        let reply = try? await send(request)
        guard let response = reply?.1 as? HTTPURLResponse else { return nil }
        return Self.probe(response)
    }

    /// The probe: Claude Code's own request shape for a subscription login, the smallest it can be.
    nonisolated static func probeRequest(bearer: String) -> URLRequest? {
        guard let url = URL(string: "https://api.anthropic.com/v1/messages") else { return nil }
        var request = URLRequest(url: url, timeoutInterval: probeTimeout)
        request.httpMethod = "POST"
        request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = ["model": probeModel, "max_tokens": 1, "system": "You are Claude Code, Anthropic's official CLI for Claude.",
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

    /// The harness login rules' refusal for a new machine of a start that may show no prompt, before it is made:
    /// a new machine is the person's own, on an owner guest, with no login of its own. Nil when the start goes on, or
    /// the verdict needs a read only the start makes (a Release build's remote switch, unread here, counts as off).
    public func loginRefusal(harness: String?, login: CloudHarnessLoginAsk, userID: String?, teamID: String?, otherTeams: [String?],
                             dogfood: Bool) async -> CloudHarnessLoginDecision.Reason? {
        guard login.headless, let userID else { return nil }
        var decision = CloudHarnessLoginDecision(dogfood: dogfood, setting: CloudCredentialTransfer.passHarnessLoginSetting(.standard),
                                                 harness: harness, signedIn: true)
        login.apply(to: &decision, userID: userID) // keeps a person's own --login, as the start itself does
        decision.callerOwns = true
        decision.guestStdout = "vm-kind:owner\n"
        decision.machineLogin = CloudMachineLogin.none
        if decision.verdict.transferProvider == .claude {
            decision.cached = await CloudCredentialTransfer.cachedLogin(provider: .claude, teamID: teamID, userID: userID, otherTeams: otherTeams) == .cached
        }
        return decision.refusal
    }
}
