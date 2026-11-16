@testable import CmuxNextActions
import Foundation
import os
import Testing

/// #44060: an Objective-C exception that unwinds a Swift job and is caught by an older system frame
/// leaves the runtime's executor record pointing at dead stack memory below the current frame; the
/// next main-actor isolation check (`sendEvent:`) segfaulted on it (#44185 too). The process now
/// repairs the slots instead of crashing. Each case runs on a fresh thread
/// of its own, so the executor slot it reads or sets is never another test's.
@Suite struct SwiftExecutorFramesTests {
    @Test func noRecordWhereNoJobRuns() async {
        let state = await onFreshThread { (SwiftExecutorFrames.activeRecord(), SwiftExecutorFrames.deadRecord()) }
        #expect(state.0 == nil)
        #expect(state.1 == nil)
    }

    @available(macOS 26, *)
    @Test func aRunningJobsRecordIsLiveNotDead() async {
        let state = await onFreshThread { () -> (active: Bool, dead: Bool) in
            let seen = OSAllocatedUnfairLock(initialState: (active: false, dead: true))
            _ = Task.immediate {
                let active = SwiftExecutorFrames.activeRecord() != nil, dead = SwiftExecutorFrames.deadRecord() != nil
                seen.withLock { $0 = (active, dead) }
            }
            return seen.withLock { $0 }
        }
        #expect(state.active, "Task.immediate runs inline on the calling thread with a record set")
        #expect(!state.dead)
    }

    /// The state the crashed process was in: the slot points into a frame that has returned (what an
    /// exception unwinding the job leaves), so the record lies below the current frame.
    @Test func aRecordInAFrameThatReturnedIsDead() async {
        let state = await onFreshThread { () -> (set: UInt, dead: UInt?) in
            let returned = addressInAReturnedFrame()
            pthread_setspecific(SwiftExecutorFrames.trackingKey, UnsafeRawPointer(bitPattern: returned))
            defer { pthread_setspecific(SwiftExecutorFrames.trackingKey, nil) }
            return (returned, SwiftExecutorFrames.deadRecord())
        }
        #expect(state.dead == state.set)
    }

    @available(macOS 26, *)
    @Test func theGuardStaysOutOfTheWayWithoutAnException() async {
        let state = await onFreshThread { () -> (value: Int, unwound: Bool, dead: Bool) in
            let seen = OSAllocatedUnfairLock(initialState: (value: 0, unwound: false))
            _ = Task.immediate {
                let value = SwiftExecutorFrames.guardingUnwind("test", restoring: .current(), onUnwind: { seen.withLock { $0.unwound = true } }) { 42 }
                seen.withLock { $0.value = value }
            }
            let result = seen.withLock { $0 }
            return (result.value, result.unwound, SwiftExecutorFrames.deadRecord() != nil)
        }
        #expect(state.value == 42)
        #expect(!state.unwound)
        #expect(!state.dead)
    }

    /// #44060, #44185: `sendEvent:` met a dead record and segfaulted. Where no job runs, recovery
    /// empties both slots, so the next isolation check reads no record at all.
    @Test func aDeadRecordIsClearedWhereNoJobRuns() async {
        let state = await onFreshThread { () -> (set: UInt, recovered: UInt?, after: SwiftExecutorFrames.Slots) in
            let returned = addressInAReturnedFrame()
            SwiftExecutorFrames.Slots(record: returned, task: 0x1e).install()
            let recovered = SwiftExecutorFrames.recoverDeadRecord(in: "test")
            let after = SwiftExecutorFrames.Slots.current()
            SwiftExecutorFrames.Slots(record: 0, task: 0).install()
            return (returned, recovered, after)
        }
        #expect(state.recovered == state.set)
        #expect(state.after == SwiftExecutorFrames.Slots(record: 0, task: 0))
    }

    @Test func aLiveRecordIsLeftAlone() async {
        let state = await onFreshThread { () -> (recovered: UInt?, kept: Bool) in
            var local = 0
            let live = withUnsafeMutablePointer(to: &local) { UInt(bitPattern: $0) }
            let slots = SwiftExecutorFrames.Slots(record: live, task: 0x1e)
            slots.install()
            let recovered = SwiftExecutorFrames.recoverDeadRecord(in: "test")
            let kept = SwiftExecutorFrames.Slots.current() == slots
            SwiftExecutorFrames.Slots(record: 0, task: 0).install()
            return (recovered, kept)
        }
        #expect(state.recovered == nil)
        #expect(state.kept)
    }

    /// What the Objective-C runtime does when an exception leaves a guarded job frame: it calls the
    /// guard's handler before the catch runs. The handler must put back the slots read before the job
    /// started, as the job frame's own return would have.
    @Test func anUnwindPutsBackTheSlotsFromBeforeTheJob() async {
        let state = await onFreshThread { () -> (after: SwiftExecutorFrames.Slots, outer: SwiftExecutorFrames.Slots, unwound: Bool) in
            let outer = SwiftExecutorFrames.Slots(record: 0x7000_0000_1000, task: 0x7000_0000_2000)
            let seen = OSAllocatedUnfairLock(initialState: false)
            let handler = UnwindHandler(site: "test", outer: outer, onUnwind: { seen.withLock { $0 = true } })
            SwiftExecutorFrames.Slots(record: addressInAReturnedFrame(), task: 0x1e).install()
            handler.unwound()
            let after = SwiftExecutorFrames.Slots.current()
            SwiftExecutorFrames.Slots(record: 0, task: 0).install()
            return (after, outer, seen.withLock { $0 })
        }
        #expect(state.after == state.outer)
        #expect(state.unwound)
    }
}

/// The address of a local of a frame that has returned by the time the caller reads it, many frames
/// below the caller, as the job frame an exception unwound was below the run loop's dispatch.
@inline(never)
nonisolated private func addressInAReturnedFrame(depth: Int = 32) -> UInt {
    var pad: (UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64) = (0, 0, 0, 0, 0, 0, 0, 0)
    let deeper = depth > 0 ? addressInAReturnedFrame(depth: depth - 1) : localAddress()
    return withUnsafeMutablePointer(to: &pad) { _ in deeper }
}

@inline(never)
nonisolated private func localAddress() -> UInt {
    var local = 0
    return withUnsafeMutablePointer(to: &local) { UInt(bitPattern: $0) }
}

/// Runs `body` on a new thread and returns its result.
nonisolated private func onFreshThread<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
    await withCheckedContinuation { continuation in
        Thread { continuation.resume(returning: body()) }.start()
    }
}
