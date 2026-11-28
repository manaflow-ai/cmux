import CmuxMobileModel
import CmuxMobileTransport
import Foundation

#if os(iOS)
/// cmux Dev's Try a pull request picker over the Mac's `try-pr` service
/// (PROTOCOL.md `try-pr`, hostd `try_pr.rs`).
extension LiveCoordinator: TryPullRequestService {
    private func tryPullRequestChannel(_ macID: String, args: [String: String]) async throws -> any LinkChannel {
        // A Mac with no link opens one; the page tries again when asked.
        touch(macID)
        guard let owner = sessions[macID] else { throw LinkError(code: "no-link", message: "Not connected to this Mac.") }
        let link = try await pairedLink(owner)
        return try await link.openChannel(service: "try-pr", args: args)
    }

    private static func refusal(_ channel: any LinkChannel, _ what: String) -> LinkError {
        guard let closed = channel.closedBy, closed.code != "eof" else {
            return LinkError(code: "bad_reply", message: "The Mac sent no \(what).")
        }
        if closed.code == "unknown_service" {
            return LinkError(code: closed.code, message: "This Mac's cmux is too old to install pull requests.")
        }
        return LinkError(code: closed.code, message: closed.message.isEmpty ? closed.code : closed.message)
    }

    public func tryPullRequests(macID: String) async throws -> TryPullRequestList {
        let channel = try await tryPullRequestChannel(macID, args: ["op": "list"])
        defer { Task { await channel.close(code: "eof", reason: "") } }
        guard let frame = try await channel.receive() else { throw Self.refusal(channel, "list") }
        guard let list = TryPullRequestList.decode(frame) else {
            throw LinkError(code: "bad_reply", message: "The Mac's pull request list did not read.")
        }
        return list
    }

    public func installPullRequest(macID: String, number: Int) -> AsyncThrowingStream<TryInstallEvent, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task { @MainActor in
                do {
                    let channel = try await self.tryPullRequestChannel(macID, args: ["op": "install", "pr": String(number)])
                    while let frame = try await channel.receive() {
                        guard let event = TryInstallEvent.decode(frame) else { continue }
                        continuation.yield(event)
                        if case .done = event {
                            continuation.finish()
                            return
                        }
                    }
                    continuation.finish(throwing: Self.refusal(channel, "result"))
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
#endif
