public import CMUXAuthCore
public import CmuxNextCloud
public import Foundation

/// "Pair Another Machine…" over the cmux cloud: `server.pair.invite` (origin user) through the API Worker as the
/// signed-in user, and the invite's watch socket, which the bundled `cmux` opens in Rust (`cmux cloud pair-invite-watch`).
/// The socket pushes every change; nothing polls. Preview and approve are Add Server's own.
extension PairInviteService {
    /// The refusal texts the invite shows (the App's refusal catalog).
    public nonisolated struct CloudTexts: Sendable {
        /// The Worker refused to mint: its message in a sentence.
        public var failed: @Sendable (String) -> String
        /// The Worker could not be reached.
        public var unreachable: String
        /// The Worker answered with no invite in it.
        public var notMade: String

        public init(failed: @escaping @Sendable (String) -> String, unreachable: String, notMade: String) {
            self.failed = failed
            self.unreachable = unreachable
            self.notMade = notMade
        }
    }

    /// - Parameters:
    ///   - team: The id of the Worker team the invite enrolls into, or nil when signed out.
    ///   - call: One POST to the API Worker as the signed-in user, returning the reply's `value`
    ///     (a Worker error reply throws ``FeedServiceError/owner(code:message:)``).
    ///   - apiBaseURL: The API Worker the socket opens on.
    ///   - buildSpace: The build's cloud data space (`CloudConfiguration.buildSpace`), on the socket's upgrade as on
    ///     every other Worker request; a misconfigured dev build opens no socket.
    ///   - lines: The bundled `cmux` that runs the watch (`CloudCLICall.lines(timeout: PairInviteService.watchLimit)`).
    @MainActor
    public static func cloud(team: @escaping @MainActor @Sendable () async throws -> String?,
                             call: @escaping @MainActor @Sendable (_ path: String, _ body: [String: Any]) async throws -> Any?,
                             texts: CloudTexts, apiBaseURL: URL, buildSpace: CMUXBuildSpaceState,
                             lines: @escaping CloudCLICall.Lines) -> PairInviteService {
        PairInviteService(
            mint: { @MainActor in
                do {
                    guard let team = try await team() else { return .failure(.signedOut) }
                    let body: [String: Any] = [
                        "op": "server.pair.invite",
                        "params": ["team": team],
                        "idempotency_key": "server-pair-invite-\(UUID().uuidString)",
                        "origin": "user",
                    ]
                    guard let invite = PairInvite.decode(try await call("v1/ops", body)) else {
                        return .failure(.refused(texts.notMade))
                    }
                    return .success(invite)
                } catch FeedServiceError.signedOut {
                    return .failure(.signedOut)
                } catch let refusal as CMUXBuildSpaceError {
                    return .failure(.refused(refusal.localizedDescription))
                } catch let FeedServiceError.owner(_, message) {
                    return .failure(.refused(texts.failed(message)))
                } catch {
                    return .failure(.refused(texts.unreachable))
                }
            },
            watch: { invite in
                AsyncStream(bufferingPolicy: .bufferingNewest(16)) { continuation in
                    // A misconfigured dev build's refusal: the watch reads as lost, never as nightly's socket.
                    guard let environment = try? Self.watchEnvironment(buildSpace),
                          let stdin = Self.watchRequest(apiBaseURL, invite: invite) else {
                        continuation.yield(.lost)
                        continuation.finish()
                        return
                    }
                    // task-owner: the invite's watch child; ends when its socket closes or the stream's consumer stops.
                    let task = Task { await Self.watch(lines, stdin: stdin, environment: environment, invite: invite, into: continuation) }
                    continuation.onTermination = { _ in task.cancel() }
                }
            })
    }

    /// The longest one watch runs: an invite lives ten minutes; the Worker closes the socket at its expiry.
    public nonisolated static let watchLimit: Duration = .seconds(30 * 60)

    /// The watch child's stdin: `{api, invite, secret}` (the secret never goes in argv).
    nonisolated static func watchRequest(_ base: URL, invite: PairInvite) -> Data? {
        try? JSONSerialization.data(withJSONObject: ["api": base.absoluteString, "invite": invite.code, "secret": invite.watchSecret])
    }

    /// The app's environment with this build's `CMUX_BUILD_SPACE` (the Rust socket's build space header); throws
    /// ``CMUXBuildSpaceError`` for a misconfigured dev build, which opens no socket.
    nonisolated static func watchEnvironment(_ buildSpace: CMUXBuildSpaceState) throws -> [String: String] {
        _ = try buildSpace.headers()
        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_BUILD_SPACE"] = buildSpace.childEnvironmentValue
        return environment
    }

    /// One child for one invite: each frame line yielded, then why the socket closed (``closed(_:invite:now:)``), from
    /// the child's `{"closed": CODE}` line or, when it printed none, its exit.
    nonisolated static func watch(_ lines: CloudCLICall.Lines, stdin: Data, environment: [String: String], invite: PairInvite,
                                  into continuation: AsyncStream<PairInviteFrame>.Continuation) async {
        await lines(["cloud", "pair-invite-watch"], stdin, environment) { line in
            if let close = closeCode(line) {
                continuation.yield(closed(close, invite: invite, now: Date()))
                continuation.finish()
            } else if let frame = PairInviteFrame.decode(line) {
                continuation.yield(frame)
            }
        }
        if !Task.isCancelled { continuation.yield(closed(-1, invite: invite, now: Date())) }
        continuation.finish()
    }

    /// The child's last line, `{"closed": CODE|null}`: the code, -1 for none; nil for any other line.
    nonisolated static func closeCode(_ line: Data) -> Int? {
        guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              let value = object["closed"] else { return nil }
        return (value as? NSNumber).map(\.intValue) ?? -1
    }

    /// Why the socket closed: the Worker's 4408 at expiry, or a close at about the code's expiry
    /// (Foundation may report a private close code as invalid), is the expiry; anything else is lost.
    nonisolated static func closed(_ code: Int, invite: PairInvite, now: Date) -> PairInviteFrame {
        if code == PairInviteFrame.expiryCloseCode || now >= invite.expiresAt.addingTimeInterval(-expirySlack) { return .expired }
        return .lost
    }

    /// How early a close still reads as the expiry (the Worker's alarm and this Mac's clock differ).
    nonisolated static let expirySlack: TimeInterval = 15
}

/// A server source with no local server behind it: a cloud-only approver (the invite card's: preview
/// and approve go to the cloud) wraps it, so it answers nothing.
@MainActor
public final class NoLocalServerSource: ServerSource {
    public init() {}
    public func start(_ sink: @escaping @MainActor (ServerSourceEvent) -> Void) {}
    public func send(_ intent: ServerIntent) {}
    public func stop() {}
}
