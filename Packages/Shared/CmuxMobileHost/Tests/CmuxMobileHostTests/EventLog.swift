import CmuxBrowserStream
import Foundation

/// Collects a client's events in the background so tests can check them
/// without consuming the stream themselves.
actor EventLog {
    private(set) var events: [BrowserStreamEvent] = []
    private var task: Task<Void, Never>?

    func start(_ stream: AsyncStream<BrowserStreamEvent>) {
        task = Task { [weak self] in
            for await event in stream { await self?.append(event) }
        }
    }

    func contains(_ event: BrowserStreamEvent) -> Bool {
        events.contains(event)
    }

    private func append(_ event: BrowserStreamEvent) {
        events.append(event)
    }
}
