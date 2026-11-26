import CmuxNextCloud
import CmuxNextSettings
public import Foundation

/// The consent dialog `auth.session.request` shows, as Rust's `request_answer` made it.
public struct SessionConsentAsk: Sendable, Equatable {
    public var title: String
    public var message: String
    public var allow: String
    public var deny: String
    /// No answer in this long is the deny.
    public var timeout: Duration
    /// The answer to a deny or a timeout.
    public var declined: ControlError
    /// The labels the web route records for the new session.
    public var bundleID: String
    public var tag: String?
}

/// The web route call NIGHTLY makes on "Sign In" (Rust's `mint_request`).
public struct SessionConsentMintCall: Sendable, Equatable {
    public var url: URL
    /// `{"recipient":{"bundleId","tag"}}`.
    public var body: Data
}

/// The consent session request's rules, asked of Rust (cmux-cloud-config `handoff`, ops `cloud_handoff_*`).
/// An FFI that does not answer refuses: no rules, no session.
struct SessionConsentRules: Sendable {
    /// What Rust reads for one request.
    struct Facts: Encodable {
        struct Signer: Encodable { var identifier: String, teamId: String?, path: String? }
        struct Nightly: Encodable { var stackProjectId: String, apiOrigin: String, signedIn: Bool, accountEmail: String? }
        var peerUidMatches: Bool
        var signer: Signer?
        var params: [String: JSONValue]
        var nightly: Nightly
        var consentPending: Bool
    }

    enum Decision: Sendable, Equatable {
        case refuse(ControlError)
        case ask(SessionConsentAsk)
    }

    static let unavailable = ControlError(code: "unavailable", message: "session request refused: this cmux NIGHTLY could not check it")

    /// Rust's refusal or dialog for `facts`; a malformed request or a silent FFI refuses.
    func decision(_ facts: Facts) -> Decision {
        struct Pair: Decodable { var code: String, message: String }
        struct Recipient: Decodable { var bundleId: String, tag: String? }
        struct Reply: Decodable {
            var kind: String
            var code: String?, message: String?, title: String?, allow: String?, deny: String?
            var timeoutSeconds: Int?, declined: Pair?, recipient: Recipient?
        }
        guard let reply = CloudStartCore().call("cloud_handoff_request_answer", facts, as: Reply.self) else {
            return .refuse(Self.unavailable)
        }
        if reply.kind == "askConsent", let title = reply.title, let message = reply.message, let allow = reply.allow,
           let deny = reply.deny, let seconds = reply.timeoutSeconds, let declined = reply.declined,
           let recipient = reply.recipient {
            return .ask(SessionConsentAsk(title: title, message: message, allow: allow, deny: deny, timeout: .seconds(seconds),
                                          declined: ControlError(code: declined.code, message: declined.message),
                                          bundleID: recipient.bundleId, tag: recipient.tag))
        }
        guard reply.kind == "refuse", let code = reply.code, let message = reply.message else { return .refuse(Self.unavailable) }
        return .refuse(ControlError(code: code, message: message))
    }

    /// The route call for `ask`'s recipient under `authWebOrigin`.
    func mintCall(authWebOrigin: String, ask: SessionConsentAsk) -> SessionConsentMintCall? {
        struct Request: Encodable { var authWebOrigin: String, bundleId: String, tag: String? }
        struct Reply: Decodable { var url: String, body: JSONValue }
        guard let reply = CloudStartCore().call("cloud_handoff_mint_request",
                                                Request(authWebOrigin: authWebOrigin, bundleId: ask.bundleID, tag: ask.tag),
                                                as: Reply.self),
              let url = URL(string: reply.url), let body = try? JSONEncoder().encode(reply.body) else { return nil }
        return SessionConsentMintCall(url: url, body: body)
    }

    /// The socket result (`{"access_token","refresh_token","expires_at"}`) of the route's answer, or its refusal.
    func mintResult(status: Int, body: Data) -> Result<JSONValue, ControlError> {
        struct Request: Encodable { var status: Int, body: String }
        struct Pair: Decodable { var code: String, message: String }
        struct Reply: Decodable { var result: JSONValue?, refusal: Pair? }
        let request = Request(status: max(0, min(status, 999)), body: String(decoding: body, as: UTF8.self))
        guard let reply = CloudStartCore().call("cloud_handoff_mint_answer", request, as: Reply.self) else {
            return .failure(Self.unavailable)
        }
        if let result = reply.result { return .success(result) }
        let refusal = reply.refusal ?? Pair(code: Self.unavailable.code, message: Self.unavailable.message)
        return .failure(ControlError(code: refusal.code, message: refusal.message))
    }
}
