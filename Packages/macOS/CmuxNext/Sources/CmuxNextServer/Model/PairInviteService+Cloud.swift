import CmuxNextCloud
public import Foundation

/// "Pair Another Machine…" over the cmux cloud: `server.pair.invite` (origin user) through the API
/// Worker as the signed-in user, and the invite's watch socket (`GET /v1/pair/invite/wait?invite=CODE`,
/// subprotocols `cmux.pair-invite.v1, watch.<secret>`). The socket pushes every change; nothing
/// polls. Preview and approve are Add Server's own. The App supplies the Worker call, the team and
/// the refusal texts.
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
    @MainActor
    public static func cloud(team: @escaping @MainActor @Sendable () async throws -> String?,
                             call: @escaping @MainActor @Sendable (_ path: String, _ body: [String: Any]) async throws -> Any?,
                             texts: CloudTexts, apiBaseURL: URL) -> PairInviteService {
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
                } catch let FeedServiceError.owner(_, message) {
                    return .failure(.refused(texts.failed(message)))
                } catch {
                    return .failure(.refused(texts.unreachable))
                }
            },
            watch: { invite in
                let url = Self.watchURL(apiBaseURL, invite: invite.code)
                return AsyncStream(bufferingPolicy: .bufferingNewest(16)) { continuation in
                    // task-owner: the invite's watch socket; ends when the socket closes or the stream's consumer stops.
                    let task = Task { await Self.watch(url, invite: invite, into: continuation) }
                    continuation.onTermination = { _ in task.cancel() }
                }
            })
    }

    /// `wss://…/v1/pair/invite/wait?invite=CODE` on the API Worker (`ws://` for a local http one).
    nonisolated static func watchURL(_ base: URL, invite: String) -> URL {
        var components = URLComponents(url: base.appendingPathComponent("v1/pair/invite/wait"), resolvingAgainstBaseURL: false)
            ?? URLComponents()
        components.scheme = components.scheme == "http" ? "ws" : "wss"
        components.queryItems = [URLQueryItem(name: "invite", value: invite)]
        return components.url ?? base
    }

    /// One socket for one invite: each text frame decoded and yielded, then one last frame saying why
    /// it closed (``PairInviteFrame/expired`` at the code's expiry, else ``PairInviteFrame/lost``).
    /// Event driven: each turn awaits the next frame; a closed socket throws and ends it.
    nonisolated private static func watch(_ url: URL, invite: PairInvite, into continuation: AsyncStream<PairInviteFrame>.Continuation) async {
        let task = URLSession.shared.webSocketTask(with: url, protocols: PairInviteFrame.protocols(secret: invite.watchSecret))
        task.maximumMessageSize = 64 << 10
        task.resume()
        defer {
            task.cancel(with: .goingAway, reason: nil)
            continuation.finish()
        }
        // receive() ignores task cancellation: the handler closes the socket, so a stopped watch yields nothing more.
        await withTaskCancellationHandler {
            // wakeup-allow: each turn awaits the next pushed frame; a closed socket throws and ends the loop.
            while !Task.isCancelled {
                let message: URLSessionWebSocketTask.Message
                do {
                    message = try await task.receive()
                } catch {
                    guard !Task.isCancelled else { return }
                    continuation.yield(closed(task.closeCode.rawValue, invite: invite, now: Date()))
                    return
                }
                let data: Data
                switch message {
                case let .string(text): data = Data(text.utf8)
                case let .data(bytes): data = bytes
                @unknown default: continue
                }
                if let frame = PairInviteFrame.decode(data) { continuation.yield(frame) }
            }
        } onCancel: {
            task.cancel(with: .goingAway, reason: nil)
        }
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

extension PairInviteCardPanel {
    /// The previews' and tests' card: the mock invite over the mock server's preview.
    @MainActor
    public static func mock() -> PairInviteCardPanel {
        let approver = ServerModel(source: MockServerSource(scenario: .healthyMac))
        approver.start()
        return PairInviteCardPanel(model: PairInviteModel(service: .mock(), approver: approver))
    }
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
