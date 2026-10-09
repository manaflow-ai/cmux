import CmuxNextDaemon
import Foundation

/// The Mac side of the host credential relay (cx-wb5.63, slice B of
/// cx-wb5.57; cmux-tui-core `apps/relay.rs`): a first-party app server
/// (`cmux/cloud`) sends `relay.op` / `relay.session`; the supervisor routes
/// them to this app's `credential` provider family as
/// `credential.relay {op, params, idempotency_key?, origin?}` and
/// `credential.session {}`. The app calls the API Worker with its INSTALL
/// token (never the Stack bearer; chief decision 2026-10-08): a read goes
/// to `POST /v1/read`, a keyed op to `POST /v1/ops`. The Worker's answer
/// goes back unchanged as the provider ABI body; the server sees no
/// credential and the daemon never sees one.
nonisolated struct CloudCredentialRelay: Sendable {
    /// The provider family this relay serves.
    static let family = "credential"
    static let relayOp = "credential.relay"
    static let sessionOp = "credential.session"

    /// POSTs `body` to `path` on the API Worker with `bearer`; returns the
    /// status and the body. Never logs the bearer.
    typealias Post = @Sendable (_ path: String, _ body: Data, _ bearer: String) async throws -> (status: Int, body: Data)

    struct Session: Sendable, Equatable {
        var signedIn: Bool
        var team: String?
    }

    /// One provider answer: `ok` and the ABI body.
    struct Answer: Sendable, Equatable {
        var ok: Bool
        var body: JSONValue
    }

    let post: Post
    /// A valid install token; throws when no user is signed in or the mint fails.
    let token: @Sendable () async throws -> String
    /// The Worker refused the token (401): the next ``token`` mints again.
    let invalidate: @Sendable () async -> Void
    let session: @Sendable () async -> Session

    /// Answers one provider call of the `credential` family (red: not served yet).
    func answer(_ call: AppsProviderCall) async -> Answer {
        Self.failure("operation.unsupported", "\(call.op) is not served yet")
    }

    static func answer(status: Int, body: Data) -> Answer {
        failure("operation.unsupported", "not served yet")
    }

    static let notSignedIn = failure("not_signed_in", "sign in to cmux")

    static func failure(_ code: String, _ message: String, retryable: Bool = false) -> Answer {
        Answer(ok: false, body: .object(["code": .string(code), "message": .string(message), "retryable": .bool(retryable)]))
    }
}
