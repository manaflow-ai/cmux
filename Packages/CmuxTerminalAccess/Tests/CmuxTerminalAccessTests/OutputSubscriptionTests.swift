import Foundation
import Testing
@testable import CmuxTerminalAccess

@Suite struct OutputSubscriptionTests {
    @Test func cancelFiresOnCancelOnce() {
        let counter = NSLock()
        nonisolated(unsafe) var n = 0
        let sub = OutputSubscription(
            id: UUID(), handle: .uuid(UUID()), mode: .raw,
            onCancel: { counter.lock(); n += 1; counter.unlock() }
        )
        sub.cancel()
        sub.cancel()
        #expect(n == 1)
    }

    @Test func signalEndInvokesOnEndOnce() async {
        let lock = NSLock()
        nonisolated(unsafe) var count = 0
        let sub = OutputSubscription(
            id: UUID(), handle: .uuid(UUID()), mode: .raw, onCancel: {}
        )
        sub.onEnd = { lock.lock(); count += 1; lock.unlock() }
        sub.signalEnd()
        sub.signalEnd()
        #expect(count == 1)
    }

    @Test func eventsStreamReceivesYields() async {
        let sub = OutputSubscription(
            id: UUID(), handle: .uuid(UUID()), mode: .raw, onCancel: {}
        )
        let stream = sub.events()
        sub.yield(.rawBytes(Data([0x41]), seq: 1))
        sub.yield(.rawBytes(Data([0x42]), seq: 2))
        sub.finish()
        var collected: [UInt64] = []
        for await ev in stream {
            if case .rawBytes(_, let s) = ev { collected.append(s) }
        }
        #expect(collected == [1, 2])
    }

    @Test func preEventsYieldsAreBufferedAndReplayed() async {
        let sub = OutputSubscription(
            id: UUID(), handle: .uuid(UUID()), mode: .raw, onCancel: {}
        )
        // Yield BEFORE attaching the stream — should buffer.
        sub.yield(.rawBytes(Data([0x01]), seq: 1))
        sub.yield(.rawBytes(Data([0x02]), seq: 2))
        let stream = sub.events()
        sub.finish()
        var collected: [UInt64] = []
        for await ev in stream {
            if case .rawBytes(_, let s) = ev { collected.append(s) }
        }
        #expect(collected == [1, 2])
    }

    @Test func yieldAfterCancelIsNoOp() async {
        let sub = OutputSubscription(
            id: UUID(), handle: .uuid(UUID()), mode: .raw, onCancel: {}
        )
        let stream = sub.events()
        sub.cancel()
        sub.yield(.rawBytes(Data([0xFF]), seq: 99))
        var count = 0
        for await _ in stream { count += 1 }
        #expect(count == 0)
    }
}
