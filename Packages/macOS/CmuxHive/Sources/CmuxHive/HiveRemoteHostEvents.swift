import CmuxMobileRPC
import Foundation

/// Owns one host subscription shared by workspace and render-grid consumers.
@MainActor
final class HiveRemoteHostEvents {
    private let client: MobileCoreRPCClient
    private let streamID = UUID().uuidString
    private var subscribed = false
    private var generation = 0
    private var pending: Task<Void, any Error>?

    init(client: MobileCoreRPCClient) {
        self.client = client
    }

    /// Coalesces concurrent setup; a stable ID makes recovery idempotent on the host.
    func ensureSubscribed() async throws {
        guard !subscribed else { return }
        let task: Task<Void, any Error>
        if let pending {
            task = pending
        } else {
            generation &+= 1
            let client = self.client
            let streamID = self.streamID
            task = Task {
                let request = try MobileCoreRPCClient.requestData(
                    method: "mobile.events.subscribe",
                    params: [
                        "stream_id": streamID,
                        "topics": ["workspace.updated", "terminal.render_grid"],
                    ]
                )
                _ = try await client.sendRequest(request)
            }
            pending = task
        }
        let attempt = generation
        do {
            try await task.value
            guard attempt == generation else { throw CancellationError() }
            subscribed = true
            pending = nil
        } catch {
            if attempt == generation { pending = nil }
            throw error
        }
    }

    /// A lost authoritative event stream requires re-admission on the next request.
    func invalidate() {
        generation &+= 1
        subscribed = false
        pending?.cancel()
        pending = nil
    }
}
