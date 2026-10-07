import CmuxTerminalRenderCore
import Foundation

/// On-demand scrollback for one source (c1-terminal-rpc.md section 7): the
/// oldest history offset this viewer holds, whether a `terminal.history`
/// request is out, and the state the screen shows. A host that refuses
/// (`proto.unsupported` until cmux-tui pages history) is not asked again.
struct TerminalHistoryTracker {
    static let pageBytes = 256 * 1024

    private(set) var state: TerminalHistoryState = .idle
    private(set) var oldestOffset: UInt64?
    private var subscribers: [UUID: AsyncStream<TerminalHistoryState>.Continuation] = [:]

    /// A request may go out now (none pending, host not known to refuse).
    var canRequest: Bool { state != .loading && state != .unavailable }

    mutating func subscribe(onTermination: @escaping @Sendable (UUID) -> Void) -> AsyncStream<TerminalHistoryState> {
        let (stream, continuation) = AsyncStream<TerminalHistoryState>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let id = UUID()
        subscribers[id] = continuation
        continuation.yield(state)
        continuation.onTermination = { _ in onTermination(id) }
        return stream
    }

    mutating func unsubscribe(_ id: UUID) {
        subscribers[id] = nil
    }

    mutating func requested() { set(.loading) }

    /// A `snapshot_history` page (the first ones come with every READY).
    mutating func received(offset: UInt64) {
        oldestOffset = min(oldestOffset ?? offset, offset)
        if state == .loading { set(.loaded) }
    }

    /// The host answered the channel with an error while a request was out.
    mutating func refused() {
        if state == .loading { set(.unavailable) }
    }

    mutating func finish() {
        for continuation in subscribers.values { continuation.finish() }
        subscribers.removeAll()
    }

    private mutating func set(_ next: TerminalHistoryState) {
        guard next != state else { return }
        state = next
        for continuation in subscribers.values { continuation.yield(next) }
    }
}
