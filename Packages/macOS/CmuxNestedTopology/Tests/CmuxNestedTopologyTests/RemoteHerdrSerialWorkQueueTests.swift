import Foundation
import Testing
@testable import CmuxNestedTopology

@Suite struct RemoteHerdrSerialWorkQueueTests {
    actor AppliedBox {
        var value = ""
        func set(_ next: String) { value = next }
        func get() -> String { value }
    }

    actor Gate {
        private var started = false
        private var released = false

        func markStarted() { started = true }
        func isStarted() -> Bool { started }
        func markReleased() { released = true }
        func isReleased() -> Bool { released }
    }

    private func waitUntil(_ predicate: @escaping @Sendable () async -> Bool) async {
        for _ in 0..<400 {
            if await predicate() { return }
            try? await Task.sleep(for: .milliseconds(1))
        }
    }

    @Test func laterSnapshotRemainsApplied() async {
        let queue = RemoteHerdrSerialWorkQueue()
        let box = AppliedBox()
        let gate = Gate()
        let firstTask = Task {
            await queue.enqueue(.snapshot) {
                await gate.markStarted()
                await self.waitUntil { await gate.isReleased() }
                await box.set("old")
                return "old"
            }
        }
        await waitUntil { await gate.isStarted() }
        let secondTask = Task {
            await queue.enqueue(.snapshot) {
                await box.set("new")
                return "new"
            }
        }
        await gate.markReleased()
        let first = await firstTask.value
        let second = await secondTask.value
        #expect(first == "old")
        #expect(second == "new")
        #expect(await box.get() == "new")
    }

    @Test func laterSendOnSamePaneRemainsApplied() async {
        let queue = RemoteHerdrSerialWorkQueue()
        let box = AppliedBox()
        let gate = Gate()
        let firstTask = Task {
            await queue.enqueue(.send(paneID: "p1")) {
                await gate.markStarted()
                await self.waitUntil { await gate.isReleased() }
                await box.set("old-keys")
                return "old-keys"
            }
        }
        await waitUntil { await gate.isStarted() }
        let secondTask = Task {
            await queue.enqueue(.send(paneID: "p1")) {
                await box.set("new-keys")
                return "new-keys"
            }
        }
        await gate.markReleased()
        _ = await (firstTask.value, secondTask.value)
        #expect(await box.get() == "new-keys")
        #expect(await queue.trackedStreamCount() == 0)
    }

    @Test func idleSendStreamsArePruned() async {
        let queue = RemoteHerdrSerialWorkQueue()
        _ = await queue.enqueue(.send(paneID: "p1")) { "a" }
        _ = await queue.enqueue(.send(paneID: "p2")) { "b" }
        #expect(await queue.trackedStreamCount() == 0)
    }

    @Test func inFlightSendStreamRemainsTrackedUntilIdle() async {
        let queue = RemoteHerdrSerialWorkQueue()
        let gate = Gate()
        let firstTask = Task {
            await queue.enqueue(.send(paneID: "p1")) {
                await gate.markStarted()
                await self.waitUntil { await gate.isReleased() }
                return "done"
            }
        }
        await waitUntil { await gate.isStarted() }
        #expect(await queue.trackedStreamCount() == 1)
        await gate.markReleased()
        _ = await firstTask.value
        #expect(await queue.trackedStreamCount() == 0)
    }
}
