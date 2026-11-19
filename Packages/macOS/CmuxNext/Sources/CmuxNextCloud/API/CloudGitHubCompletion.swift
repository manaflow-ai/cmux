import CryptoKit
public import Foundation
import Observation
import os

/// How many GitHub completions answered this launch (``CloudGitHubCompletion/handle(_:auth:now:)``), one per sign-in
/// (``CloudAuth/gitHubChanges``): Settings' GitHub and each chat's folder menu observe it and read GitHub again, so the
/// repositories list with no restart and no click.
@MainActor @Observable public final class CloudGitHubChanges {
    public internal(set) var count = 0
    public init() {}
}

/// The connects this app started and may finish itself (#46018), one per connection, this launch only, never on disk.
///
/// Each connect asks with the hash of a fresh random secret (`attempt_hash`); the API's signed state carries only the
/// hash. The console's callback hands GitHub's answer to the API and opens `<scheme>://integration/complete` with the
/// connection id and a single-use handoff value, nothing secret of the person's. The app finishes only a connection it
/// recorded here, once, before the state expires, sending the state, that handoff value and the secret with its own
/// sign-in: a completion link the app did not ask for (another app, a page, a stale link) finishes nothing.
@MainActor public final class CloudGitHubAttempts {
    /// One recorded attempt: the state the API signed for it, the secret, and when the state expires.
    public struct Attempt: Equatable, Sendable {
        public let state: String
        public let secret: String
        public let expires: Date
    }

    private var secrets: [String: (secret: String, made: Date)] = [:]
    private var attempts: [String: Attempt] = [:]
    private let newSecret: () -> String
    /// How long a secret waits for its connect's answer; a state lives 15 minutes (api src/integrations/state.ts).
    static let secretLifetime: TimeInterval = 20 * 60
    static let limit = 16

    public init(newSecret: @escaping () -> String = CloudGitHubAttempts.randomSecret) { self.newSecret = newSecret }

    /// 32 random bytes, base64url without padding (43 characters).
    public nonisolated static func randomSecret() -> String {
        var generator = SystemRandomNumberGenerator()
        return base64URL(Data((0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) }))
    }

    /// The `attempt_hash` a connect sends for `secret`: base64url SHA-256.
    public nonisolated static func hash(_ secret: String) -> String { base64URL(Data(SHA256.hash(data: Data(secret.utf8)))) }

    nonisolated static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    /// The secret for the connect asked under `key`: the same one on a retry of that key (its params must not change).
    public func secret(forKey key: String, now: Date) -> String {
        secrets = secrets.filter { now.timeIntervalSince($0.value.made) < Self.secretLifetime }
        if let kept = secrets[key] { return kept.secret }
        let secret = newSecret()
        if secrets.count >= Self.limit, let oldest = secrets.min(by: { $0.value.made < $1.value.made })?.key { secrets[oldest] = nil }
        secrets[key] = (secret, now)
        return secret
    }

    /// Records the attempt the connect under `key` answered with `page` (its installation page, whose `state` names the
    /// connection). Nothing when that key asked no secret, or the page carries no state for a connection.
    public func record(page: URL, key: String, now: Date) {
        guard let secret = secrets[key]?.secret,
              let state = URLComponents(url: page, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "state" })?.value,
              let claims = CloudGitHubCompletion.claims(ofState: state),
              let connection = claims["conn"] as? String, CloudGitHubCompletion.isConnectionID(connection),
              claims["anh"] as? String == Self.hash(secret),
              let exp = (claims["exp"] as? NSNumber)?.doubleValue else { return }
        attempts = attempts.filter { $0.value.expires > now }
        if attempts.count >= Self.limit, let oldest = attempts.min(by: { $0.value.expires < $1.value.expires })?.key { attempts[oldest] = nil }
        attempts[connection] = Attempt(state: state, secret: secret, expires: Date(timeIntervalSince1970: exp))
    }

    /// The attempt recorded for `connection`, removed (single use); nil when none was recorded or its state expired.
    public func take(connection: String, now: Date) -> Attempt? {
        guard let attempt = attempts.removeValue(forKey: connection), attempt.expires > now else { return nil }
        return attempt
    }
}

/// The console's hand-off of a connect this app started (#46018): `<scheme>://integration/complete?connection=&handoff=`.
/// It carries no provider code and no state: the API holds GitHub's answer, and this app finishes the connection with
/// its own sign-in, the state and secret it recorded (``CloudGitHubAttempts``), and the single-use handoff value.
public struct CloudGitHubCompletion: Equatable, Sendable {
    public let connection: String
    public let handoff: String

    /// The return link a connect from this build asks for: `<scheme>://integration/complete`.
    public static func link(scheme: String) -> String { "\(scheme)://integration/complete" }

    /// Whether `url` is this build's (`scheme`) completion link, well-formed or not.
    public static func isLink(_ url: URL, scheme: String) -> Bool {
        url.scheme?.lowercased() == scheme.lowercased() && url.host?.lowercased() == "integration" && url.path == "/complete"
    }

    /// `url` when it is this build's (`scheme`) completion link with a connection id and a handoff value; nil otherwise.
    public init?(url: URL, scheme: String) {
        guard Self.isLink(url, scheme: scheme), url.user == nil, url.password == nil, url.port == nil,
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return nil }
        func value(_ name: String) -> String? {
            let matches = items.filter { $0.name == name }
            guard matches.count == 1, let raw = matches[0].value, !raw.isEmpty, raw.utf8.count <= 256 else { return nil }
            return raw
        }
        guard let connection = value("connection"), Self.isConnectionID(connection),
              let handoff = value("handoff"), handoff.range(of: #"^[A-Za-z0-9_-]{43}$"#, options: .regularExpression) != nil else { return nil }
        self.connection = connection
        self.handoff = handoff
    }

    /// `conn_` and 20 lowercase letters or digits (the API's connection ids).
    static func isConnectionID(_ s: String) -> Bool { s.range(of: #"^conn_[a-z0-9]{20}$"#, options: .regularExpression) != nil }

    /// A state's claims, unverified: only this app's own record of what it asked, and where a completion is sent.
    static func claims(ofState state: String) -> [String: Any]? {
        let parts = state.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, state.utf8.count <= 4096 else { return nil }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// The state's `team` claim (`team_` and 20 hex): only where the completion is sent (`x-cmux-team`). The API checks
    /// the state's team against the session's.
    static func team(ofState state: String) -> String? {
        guard let team = claims(ofState: state)?["team"] as? String,
              team.range(of: #"^team_[0-9a-f]{20}$"#, options: .regularExpression) != nil else { return nil }
        return team
    }

    /// `integration.complete`'s params for `attempt`: the state, the handoff value and the secret. No provider code.
    public func params(_ attempt: CloudGitHubAttempts.Attempt) -> [String: String] {
        ["state": attempt.state, "handoff": handoff, "attempt": attempt.secret]
    }

    /// Keyed by the state, so a repeated link for the same attempt is the same completion.
    public static func idempotencyKey(state: String) -> String { "complete:" + String(state.suffix(40)) }
}

extension CloudGitHubCompletion {
    nonisolated static let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "cloud.github")

    /// Handles `url` when it is this build's completion link: true for every such link (none is routed anywhere else),
    /// false for any other URL. Finishes only a connect this app recorded (``CloudGitHubAttempts``), once, with `auth`'s
    /// own sign-in, then counts it in ``CloudGitHubChanges``; an unsolicited or repeated link finishes nothing.
    @MainActor public static func handle(_ url: URL, auth: CloudAuth, now: Date = Date()) -> Bool {
        let scheme = auth.configuration.callbackScheme
        guard isLink(url, scheme: scheme) else { return false }
        guard let completion = CloudGitHubCompletion(url: url, scheme: scheme) else {
            logger.notice("github completion: link without a connection hand-off, ignored")
            return true
        }
        guard let attempt = auth.gitHubAttempts.take(connection: completion.connection, now: now) else {
            logger.notice("github completion: no connect from this launch for that connection, ignored")
            return true
        }
        let base = auth.configuration.ownerAPIBaseURL(), team = team(ofState: attempt.state)
        // task-owner: fire and forget; one completion per recorded attempt, keyed so a retry is the same completion.
        Task { @MainActor in
            await auth.awaitRestored()
            guard auth.isSignedIn else { return }
            let access: CloudOwnerAPIClient.AccessToken = { try await auth.tokens().access }
            let answer = await CloudOwnerAPIClient(baseURL: base, accessToken: access, teamID: { team }).gitHubComplete(completion, attempt: attempt)
            logger.notice("github completion: \(String(describing: answer), privacy: .public)")
            auth.gitHubChanges.count += 1
        }
        return true
    }
}

extension CloudOwnerAPIClient {
    /// What one completion answered.
    public enum GitHubCompletion: Equatable, Sendable {
        case connected
        /// The API refused it (a state for someone else, expired, already used, or GitHub refused the code).
        case refused
        case noAnswer
    }

    /// `integration.complete` on `/v1/ops` as the person, in ``teamID``'s team: the recorded attempt and the hand-off.
    public func gitHubComplete(_ completion: CloudGitHubCompletion, attempt: CloudGitHubAttempts.Attempt) async -> GitHubCompletion {
        let body: [String: Any] = ["op": "integration.complete", "params": completion.params(attempt), "origin": "user", "idempotency_key": CloudGitHubCompletion.idempotencyKey(state: attempt.state)]
        guard let json = try? JSONSerialization.data(withJSONObject: body), let answer = await person("/v1/ops", post: json) else { return .noAnswer }
        return Self.completion(status: answer.status, body: answer.body)
    }

    /// A 2xx answer that says `ok` (no error) is connected; a 408, 429 or 5xx may not have run; anything else refused.
    static func completion(status: Int, body: Data) -> GitHubCompletion {
        guard status < 500, status != 408, status != 429 else { return .noAnswer }
        guard (200..<300).contains(status), let reply = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              reply["ok"] as? Bool != false, reply["error"] == nil || reply["error"] is NSNull else { return .refused }
        return .connected
    }
}
