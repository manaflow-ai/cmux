@testable import CmuxHomeCore

/// Collects every event a source publishes, on the main actor, so a test
/// waits for the one it expects with `waitUntil`.
@MainActor
final class WireEventLog {
    private(set) var events: [HomeEvent] = []
    private var reader: Task<Void, Never>?

    init(_ stream: AsyncStream<HomeEvent>) {
        reader = Task { [weak self] in
            for await event in stream { self?.events.append(event) }
        }
    }

    func stop() {
        reader?.cancel()
    }

    /// The messages published, in order.
    var messages: [(message: Message, rev: Revision)] {
        events.compactMap { if case .message(let message, let rev) = $0 { (message, rev) } else { nil } }
    }

    /// The conversation summaries published for `stream`, in order.
    func changes(on stream: HomeStream) -> [(summary: ConversationSummary, rev: Revision)] {
        events.compactMap { event in
            guard case .conversationChanged(let summary, let on, let rev) = event, on == stream else { return nil }
            return (summary, rev)
        }
    }

    var sawOnlineInbox: Bool {
        events.contains { if case .inbox = $0 { true } else { false } } && events.contains(.connection(.online))
    }
}
