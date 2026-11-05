import CmuxNextCloud
import CmuxNextDaemonService
import CmuxNextServer
import Foundation

/// "Pair Another Machine…" in the app: `server.pair.invite` (origin user) through the API Worker as
/// the signed-in user, and the invite's watch socket (`GET /v1/pair/invite/wait?invite=CODE`,
/// subprotocols `cmux.pair-invite.v1, watch.<secret>`). The socket pushes every change; nothing
/// polls. Preview and approve are Add Server's own (``CloudPairingSource``).
extension PairInviteService {
    /// - Parameters:
    ///   - pairing: The approver's source: its Worker team is the team the invite enrolls into, and
    ///     its call (`FeedService.call`, as the signed-in user) mints the invite.
    ///   - apiBaseURL: The API Worker the socket opens on.
    @MainActor
    static func app(pairing: CloudPairingSource, apiBaseURL: URL) -> PairInviteService {
        PairInviteService(
            mint: { @MainActor in
                do {
                    guard let team = try await pairing.workerTeam() else { return .failure(.signedOut) }
                    let body: [String: Any] = [
                        "op": "server.pair.invite",
                        "params": ["team": team.id],
                        "idempotency_key": "server-pair-invite-\(UUID().uuidString)",
                        "origin": "user",
                    ]
                    let reply = try await pairing.call("v1/ops", body)
                    guard let invite = PairInvite.decode(try CloudPairingSource.okValue(reply)) else {
                        return .failure(.refused(Self.notMade))
                    }
                    return .success(invite)
                } catch FeedServiceError.signedOut {
                    return .failure(.signedOut)
                } catch let FeedServiceError.owner(_, message) {
                    return .failure(.refused(RefusalStrings.format("refusal.server.inviteFailed", "Could not make a pairing code: %@", message)))
                } catch {
                    return .failure(.refused(RefusalStrings.text("refusal.server.pairUnreachable", "Could not reach cmux. Check the connection and try again.")))
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

    private static var notMade: String {
        RefusalStrings.text("refusal.server.inviteNotMade", "cmux could not make a pairing code. Try again.")
    }
}
