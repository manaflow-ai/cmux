public import Foundation
import Observation

/// How many GitHub completions answered this launch (``CloudGitHubCompletion/handle(_:auth:)``), one per sign-in
/// (``CloudAuth/gitHubChanges``): Settings' GitHub and each chat's folder menu observe it and read GitHub again, so the
/// repositories list with no restart and no click.
///
/// It also keeps the last completion the API refused (``refusal``), so the Connect GitHub button can say why the link
/// did not take instead of staying silent.
@MainActor @Observable public final class CloudGitHubChanges {
    public internal(set) var count = 0
    /// The last completion's refusal (an expired state, a non-owner's request, GitHub refusing the code); nil when the
    /// last answer connected, none came back, or a new connect started. ``count`` changes after it is set.
    public internal(set) var refusal: Refusal?
    public init() {}

    /// Why a completion was refused: the API's `reason` when it gave words that are safe to show, else nil (the link
    /// expired is the common case, and the client's own words say it).
    public struct Refusal: Equatable, Sendable {
        public let reason: String?
        public init(reason: String?) { self.reason = reason }
    }

    /// Records what a completion answered: a refusal is kept, a connection or a lost answer clears the last one.
    func record(_ answer: CloudOwnerAPIClient.GitHubCompletion, reason: String?) {
        switch answer {
        case .refused: refusal = Refusal(reason: reason)
        case .connected, .noAnswer: refusal = nil
        }
        count += 1
    }

    /// A new Connect GitHub starts over: the last refusal no longer applies.
    public func forgetRefusal() { refusal = nil }
}

/// GitHub's install redirect handed back to this app (#46018): the connect this app started named
/// `<scheme>://integration/complete` as its return link, so the console's callback sends the person's browser straight
/// on to it with GitHub's `code`, `installation_id` and the signed `state`, and shows no page and asks no web sign-in.
/// The app finishes the connection with its own sign-in (``CloudOwnerAPIClient/gitHubComplete(_:)``); the API still
/// completes only a state it signed for this same person and team.
public struct CloudGitHubCompletion: Equatable, Sendable {
    public let state: String
    public let code: String?
    public let installationID: String?
    public let setupAction: String?
    /// GitHub's `error` (the person cancelled): nothing to complete.
    public let error: String?

    /// The return link a connect from this build asks for: `<scheme>://integration/complete`.
    public static func link(scheme: String) -> String { "\(scheme)://integration/complete" }

    /// `url` when it is this build's (`scheme`) completion link with a signed state; nil for any other URL.
    public init?(url: URL, scheme: String) {
        guard url.scheme?.lowercased() == scheme.lowercased(), url.host?.lowercased() == "integration", url.path == "/complete",
              url.user == nil, url.password == nil, url.port == nil,
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return nil }
        func value(_ name: String) -> String? {
            guard let raw = items.first(where: { $0.name == name })?.value, !raw.isEmpty, raw.utf8.count <= 4096 else { return nil }
            return raw
        }
        guard let state = value("state"), state.split(separator: ".", omittingEmptySubsequences: false).count == 3 else { return nil }
        self.state = state
        code = value("code")
        installationID = value("installation_id").flatMap { $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) ? $0 : nil }
        setupAction = value("setup_action")
        error = value("error")
    }

    /// The state's `team` claim (`team_` and 20 hex), unverified: only where the completion is sent (`x-cmux-team`),
    /// as the console's callback routes it. The API checks the state's team against the session's.
    public var team: String? {
        let parts = state.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload), let claims = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let team = claims["team"] as? String,
              team.range(of: #"^team_[0-9a-f]{20}$"#, options: .regularExpression) != nil else { return nil }
        return team
    }

    /// The same key the console's callback sends, so a completion that page also sent is one completion.
    public var idempotencyKey: String { "complete:" + String(state.suffix(40)) }

    /// `integration.complete`'s params: the state and what GitHub gave.
    public var params: [String: String] {
        var params = ["state": state]
        if let code { params["code"] = code }
        if let installationID { params["installation_id"] = installationID }
        if let setupAction { params["setup_action"] = setupAction }
        return params
    }
}

extension CloudGitHubCompletion {
    /// Finishes `url` when it is this build's completion link (``CloudGitHubCompletion/link(scheme:)``) with `auth`'s
    /// own sign-in, then counts it in ``CloudGitHubChanges``; false for any other URL. A cancel on GitHub finishes nothing.
    @MainActor public static func handle(_ url: URL, auth: CloudAuth) -> Bool {
        guard let completion = CloudGitHubCompletion(url: url, scheme: auth.configuration.callbackScheme) else { return false }
        guard completion.error == nil else { return true }
        let base = auth.configuration.ownerAPIBaseURL(), team = completion.team
        // task-owner: fire and forget; one completion per redirect, keyed so a repeated link is the same completion.
        Task { @MainActor in
            await auth.awaitRestored()
            guard auth.isSignedIn else { return }
            let access: CloudOwnerAPIClient.AccessToken = { try await auth.tokens().access }
            let (answer, reason) = await CloudOwnerAPIClient(baseURL: base, accessToken: access, teamID: { team }, buildSpace: auth.configuration.buildSpace)
                .gitHubCompleteWithReason(completion)
            auth.gitHubChanges.record(answer, reason: reason)
        }
        return true
    }
}

extension CloudOwnerAPIClient {
    /// What one completion answered.
    public enum GitHubCompletion: Equatable, Sendable {
        case connected
        /// The API refused it (a state for someone else, expired, or GitHub refused the code).
        case refused
        case noAnswer
    }

    /// `integration.complete` on `/v1/ops` as the person, in ``teamID``'s team, under the console's own key.
    public func gitHubComplete(_ completion: CloudGitHubCompletion) async -> GitHubCompletion {
        await gitHubCompleteWithReason(completion).answer
    }

    /// ``gitHubComplete(_:)`` and, for a refusal, the API's own words (``refusalReason(body:)``).
    public func gitHubCompleteWithReason(_ completion: CloudGitHubCompletion) async -> (answer: GitHubCompletion, reason: String?) {
        let body: [String: Any] = ["op": "integration.complete", "params": completion.params, "origin": "user", "idempotency_key": completion.idempotencyKey]
        guard let json = try? JSONSerialization.data(withJSONObject: body), let answer = await person("/v1/ops", post: json) else { return (.noAnswer, nil) }
        let result = Self.completion(status: answer.status, body: answer.body)
        return (result, result == .refused ? Self.refusalReason(body: answer.body) : nil)
    }

    /// The API's message for a refused completion (`{error: {code, message}}`), trimmed and capped; nil when it gave none,
    /// or when it is the expired or invalid `state` (`integration.state_invalid` and kin), which the client words itself.
    static func refusalReason(body: Data) -> String? {
        guard let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              let error = object["error"] as? [String: Any] else { return nil }
        let code = (error["code"] as? String ?? "").lowercased()
        guard !code.contains("state") else { return nil }
        let text = (error["message"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : String(text.prefix(200))
    }

    /// A 2xx answer that says `ok` (no error) is connected; a 408, 429 or 5xx may not have run; anything else refused.
    static func completion(status: Int, body: Data) -> GitHubCompletion {
        guard status < 500, status != 408, status != 429 else { return .noAnswer }
        guard (200..<300).contains(status), let reply = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              reply["ok"] as? Bool != false, reply["error"] == nil || reply["error"] is NSNull else { return .refused }
        return .connected
    }
}
