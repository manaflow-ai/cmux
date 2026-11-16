@testable import CmuxNextActions
import Foundation
import os
import Testing

/// #44060: an Objective-C exception that unwinds a Swift job and is caught by an older system frame
/// leaves the runtime's executor record pointing at dead stack memory below the current frame; the
/// next main-actor isolation check (`sendEvent:`) segfaulted on it. Each case runs on a fresh thread
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
                let value = SwiftExecutorFrames.guardingUnwind("test", onUnwind: { seen.withLock { $0.unwound = true } }) { 42 }
                seen.withLock { $0.value = value }
            }
            let result = seen.withLock { $0 }
            return (result.value, result.unwound, SwiftExecutorFrames.deadRecord() != nil)
        }
        #expect(state.value == 42)
        #expect(!state.unwound)
        #expect(!state.dead)
    }
}

/// The address of a local of a frame that has returned by the time the caller reads it.
@inline(never)
nonisolated private func addressInAReturnedFrame() -> UInt {
    var deep = [UInt8](repeating: 0, count: 1)
    return deep.withUnsafeMutableBufferPointer { _ in localAddress() }
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
