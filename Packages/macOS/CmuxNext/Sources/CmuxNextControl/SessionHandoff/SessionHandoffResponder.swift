public import CmuxNextSettings
import Foundation

/// cmux NIGHTLY's answer to `auth.session.handoff` on its control socket: its signed-in Stack session,
/// to a client ``SessionHandoffPolicy/admitsClient(_:)`` admits, and nothing to anyone else.
///
/// The method is answered before the socket's access mode is consulted, because the client (a DEV
/// build) is not a process started inside NIGHTLY; the policy's uid and code-signature checks take the
/// access mode's place for this one method. The connection closes after the answer, so the handoff
/// never opens the rest of the socket. A refusal says only that it refused, never which check failed,
/// and no answer, error or log carries a token except the success line written to the admitted client.
///
/// ```swift
/// let service = try ControlService.start(registry: registry, settings: settings, launch: launch,
///     sessionHandoff: .forNightly(launch: launch, productionAuth: true, session: auth.storedSession))
/// ```
public struct SessionHandoffResponder: Sendable {
    /// NIGHTLY's current session, or nil when it is signed out.
    public typealias Session = @Sendable () async -> SessionHandoffPair?

    let policy: SessionHandoffPolicy
    let session: Session

    /// - Parameters:
    ///   - policy: Who may receive the session.
    ///   - session: Reads the session to hand out.
    public init(policy: SessionHandoffPolicy, session: @escaping Session) {
        self.policy = policy
        self.session = session
    }

    /// The responder a cmux NIGHTLY on the production account sets on its control socket, handing out
    /// `session` (its stored pair); nil for every other build, whose socket then does not know the method.
    public static func forNightly(launch: LaunchIdentity, productionAuth: Bool,
                                  session: @escaping @Sendable () async -> (accessToken: String?, refreshToken: String)?)
        -> SessionHandoffResponder? {
        guard launch.bundleID == SessionHandoffPolicy.serverBundleID, productionAuth else { return nil }
        return SessionHandoffResponder(policy: SessionHandoffPolicy()) {
            await session().flatMap { SessionHandoffPair(accessToken: $0.accessToken, refreshToken: $0.refreshToken) }
        }
    }

    /// The handoff request in `line`, or nil when the line is any other request.
    func request(in line: String) -> ControlRequest? {
        guard line.hasPrefix("{"), case .success(let request) = ControlRouter.decode(line),
              request.method == SessionHandoffPolicy.method else { return nil }
        return request
    }

    /// The response line for `request` from `peer`.
    func respond(to request: ControlRequest, peer: SessionHandoffPeer?) async -> String {
        guard policy.admitsClient(peer) else {
            return ControlRouter.encode(id: request.id, error: ControlError(code: "forbidden", message: "session handoff refused"))
        }
        guard let pair = await session() else {
            return ControlRouter.encode(id: request.id, error: ControlError(code: "not_found", message: "not signed in"))
        }
        var result: [String: JSONValue] = ["refresh_token": .string(pair.refreshToken)]
        if let access = pair.accessToken { result["access_token"] = .string(access) }
        return ControlRouter.encode(id: request.id, result: .success(.object(result)))
    }
}
