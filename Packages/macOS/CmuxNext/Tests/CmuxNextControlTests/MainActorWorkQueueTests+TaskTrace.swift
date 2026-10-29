@testable import CmuxNextControl
import CmuxNextSignposts
import CmuxNextTrace
import CmuxNextWakeups
import Testing

/// Task tracing of queued control requests (p09-observability task 042): each request is a `control.request`
/// async slice from its enqueue to its end, and a posted task: a `task.post` flow at its caller's `#fileID` and
/// `#line` and a `task.run` slice on the main thread with the flow-in.
extension MainActorWorkQueueTests {
    static func tracedQueue(_ ring: TraceRing, limits: MainActorWorkQueue.Limits = .init())
        -> (MainActorWorkQueue, ManualFrameSource) {
        let runtime = TraceRuntime(role: .app)
        _ = runtime.attach(ring)
        runtime.setCategoryMask(1 << UInt64(SignpostCategory.task.traceBit) | 1 << UInt64(SignpostCategory.control.traceBit))
        let frames = ManualFrameSource()
        return (MainActorWorkQueue(limits: limits, frameSource: frames, trace: runtime), frames)
    }

    static func records(_ image: TraceRing.Image, _ name: SignpostName, _ phase: TraceRecord.Phase) -> [TraceRecord] {
        image.records.filter { $0.name == name.rawValue && $0.phase == phase }
    }

    @Test func threeRequestsDecodeAsThreeFlowPairsWithTheirSitesAndControlSlices() async throws {
        let ring = TraceRing(records: 4096, role: .app)
        let (queue, frames) = Self.tracedQueue(ring)
        let deadline = ContinuousClock.now + .seconds(30)
        async let first: Int = queue.run(connection: ControlConnectionID(rawValue: 1), method: "a", deadline: deadline) { 1 }
        let firstLine = UInt64(#line - 1)
        async let second: Int = queue.run(connection: ControlConnectionID(rawValue: 2), method: "b", deadline: deadline) { 2 }
        let secondLine = UInt64(#line - 1)
        async let third: Int = queue.run(connection: ControlConnectionID(rawValue: 3), method: "c", deadline: deadline) { 3 }
        let thirdLine = UInt64(#line - 1)
        while queue.stats.pending < 3 { await Task.yield() }
        while queue.stats.executed < 3 { await frames.fire() }
        #expect(try await first + second + third == 6)

        let image = try #require(ring.decodedImage())
        let posts = Self.records(image, .taskPost, .flowOut)
        let arrivals = Self.records(image, .taskRun, .flowIn)
        try #require(posts.count == 3)
        #expect(Set(posts.map(\.arg1)).count == 3)
        #expect(Set(posts.map(\.arg1)) == Set(arrivals.map(\.arg1)), "each post's flow ends at its run")
        // A ring name entry holds at most 55 UTF-8 bytes (trace.md "Name table"); this #fileID is 60, so its site
        // reads cut at 55.
        let file = String(decoding: "CmuxNextControlTests/MainActorWorkQueueTests+TaskTrace.swift".utf8.prefix(55), as: UTF8.self)
        #expect(posts.allSatisfy { image.name(UInt16(truncatingIfNeeded: $0.arg0)) == file })
        #expect(Set(posts.map { $0.arg0 >> 16 & 0xFFFF_FFFF }) == [firstLine, secondLine, thirdLine])
        for post in posts {
            #expect(arrivals.first { $0.arg1 == post.arg1 }?.arg0 == post.arg0, "the run names its post's site")
        }
        // On the main lane (3) in bits 8-15, as automation work (MainWorkClass.automation.rawValue) in bits 0-7.
        let main = UInt64(TaskTrace.Lane.main.rawValue) << 8 | UInt64(TaskTrace.code(MainWorkClass.automation))
        #expect(Self.records(image, .taskRun, .begin).map(\.arg0) == [main, main, main])
        #expect(Self.records(image, .taskRun, .end).count == 3)

        let begins = Self.records(image, .controlRequest, .asyncBegin)
        let ends = Self.records(image, .controlRequest, .asyncEnd)
        #expect(begins.count == 3)
        #expect(Set(begins.map(\.arg1)) == Set(ends.map(\.arg1)), "each request's slice ends")
        #expect(ends.allSatisfy { $0.arg0 == ControlRequestTrace.Outcome.ran.rawValue })
    }

    @Test func aRequestRefusedAsBusyEndsItsControlSliceAsBusy() async throws {
        let ring = TraceRing(records: 4096, role: .app)
        let (queue, frames) = Self.tracedQueue(ring, limits: .init(maxPending: 1))
        let deadline = ContinuousClock.now + .seconds(30)
        async let first: Int = queue.run(method: "a", deadline: deadline) { 1 }
        while queue.stats.pending < 1 { await Task.yield() }
        await #expect(throws: ControlError.busy(pending: 1, limit: 1)) {
            _ = try await queue.run(method: "b", deadline: deadline) { 2 }
        }
        while queue.stats.executed < 1 { await frames.fire() }
        #expect(try await first == 1)

        let image = try #require(ring.decodedImage())
        let ends = Self.records(image, .controlRequest, .asyncEnd)
        #expect(ends.map(\.arg0).sorted() == [ControlRequestTrace.Outcome.ran.rawValue, ControlRequestTrace.Outcome.busy.rawValue])
        #expect(Self.records(image, .taskRun, .begin).count == 1, "the refused request never ran")
        let posts = Self.records(image, .taskPost, .flowOut)
        let arrivals = Self.records(image, .taskRun, .flowIn)
        #expect(posts.count == 1, "the refused request was never posted")
        #expect(Set(posts.map(\.arg1)) == Set(arrivals.map(\.arg1)), "every post's flow ends at its run")
    }
}
