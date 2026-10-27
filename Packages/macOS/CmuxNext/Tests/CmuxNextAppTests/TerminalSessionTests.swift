import AppKit
import CmuxNextCompat
@testable import CmuxNextTerminal
import CmuxNextWakeups
import Darwin
import Dispatch
import Foundation
import Testing

/// A session sends its input through one ``TerminalInputLane`` drained on the IO's own queue
/// (p04-input-058): the bytes it sends arrive in order, each handled on that queue, with no writer task
/// between the main thread and the IO.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1))) struct TerminalSessionTests {
    @Test func sentBytesReachTheIOQueueInOrder() async throws {
        _ = NSApplication.shared
        _ = GhosttyRuntime.shared
        let io = LaneRecordingTerminalIO()
        let session = TerminalSession(io: io, mainWork: MainWorkScheduler(budget: MainFrameBudget()))
        defer { session.close() }

        let sent = (0..<1_000).map { "k\($0)" }
        for text in sent { session.sendBytes(Data(text.utf8)) }

        let received = await io.waitForKeys(sent.count)
        #expect(received.map(\.text) == sent)
        #expect(received.allSatisfy { $0.onIOQueue }, "a record was handled off the IO's drain queue")
    }
}

/// A ``TerminalIO`` whose input drain records each `k`-prefixed bytes record and whether it ran on its queue.
private nonisolated final class LaneRecordingTerminalIO: TerminalIO {
    nonisolated struct Key: Sendable {
        var text: String
        var onIOQueue: Bool
    }

    let events = AsyncStream<TerminalIOEvent> { _ in }
    // qos-allow: a test drain standing for the attach input queue, which runs at this class
    private let queue = DispatchQueue(label: "com.cmuxterm.next.test.session-input", qos: .userInteractive)
    private let state = Mutex(State())

    private nonisolated struct State {
        var keys: [Key] = []
        var waiter: (count: Int, continuation: CheckedContinuation<[Key], Never>)?
    }

    func write(_ data: Data) async {}
    func resize(cols: Int, rows: Int, pixelWidth: Int, pixelHeight: Int) async {}

    func inputDrain() -> TerminalInputDrain {
        TerminalInputDrain(queue: queue) { [self] record, _ in
            guard case .bytes(let data) = record else { return .next }
            let text = String(decoding: data, as: UTF8.self)
            guard text.hasPrefix("k") else { return .next }
            let key = Key(text: text, onIOQueue: String(cString: __dispatch_queue_get_label(nil)) == queue.label)
            let ready = state.withLock { state -> (CheckedContinuation<[Key], Never>, [Key])? in
                state.keys.append(key)
                guard let waiter = state.waiter, state.keys.count >= waiter.count else { return nil }
                state.waiter = nil
                return (waiter.continuation, state.keys)
            }
            if let ready { ready.0.resume(returning: ready.1) }
            return .next
        }
    }

    /// The `k` keys once `count` arrived.
    func waitForKeys(_ count: Int) async -> [Key] {
        await withCheckedContinuation { continuation in
            let keys = state.withLock { state -> [Key]? in
                guard state.keys.count < count else { return state.keys }
                state.waiter = (count, continuation)
                return nil
            }
            if let keys { continuation.resume(returning: keys) }
        }
    }
}
