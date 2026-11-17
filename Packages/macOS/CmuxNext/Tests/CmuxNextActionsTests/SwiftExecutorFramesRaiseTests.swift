@testable import CmuxNextActions
import Foundation
import ObjectiveC
import os
import Testing

/// #44060: a real Objective-C exception that leaves a Swift job frame and is caught by a system
/// frame above it. `SwiftExecutorFramesTests` calls the guard's handler by hand; these cases raise
/// through the frames, so they show what the Objective-C runtime does with the guard. The catch is
/// Foundation's: an archive call reports an exception from `encode(with:)` as an error. Each case
/// runs on a fresh thread of its own, so the executor slots it reads or sets are never another
/// test's.
@Suite struct SwiftExecutorFramesRaiseTests {
    /// The control, with no guard: the exception skips the job frame's restore, so the slot keeps
    /// the address of a record in a frame that is gone.
    @available(macOS 26, *)
    @Test func aRaiseCaughtAboveAnUnguardedJobLeavesADeadRecord() async {
        let state = await onFreshThread { () -> RaiseOutcome in
            let box = JobFactsBox()
            let before = SwiftExecutorFrames.Slots.current()
            let caught = archiveCatches {
                _ = Task.immediate {
                    box.facts.withLock { $0.hadRecord = SwiftExecutorFrames.activeRecord() != nil }
                    raiseObjectiveCException()
                    box.facts.withLock { $0.ranPastRaise = true }
                }
            }
            return RaiseOutcome.readAndClear(before: before, caught: caught, box: box)
        }
        #expect(state.before == SwiftExecutorFrames.Slots(record: 0, task: 0))
        #expect(state.caught, "the archive call must catch the exception above the job frame")
        #expect(state.facts.hadRecord, "Task.immediate runs inline on the calling thread with a record set")
        #expect(!state.facts.ranPastRaise)
        #expect(state.after.record != 0, "slots after the catch: \(state.after)")
        #expect(state.dead != nil, "slots after the catch: \(state.after)")
    }

    /// The guard in the form `TaskLocal.withValueInTask` uses it: the slots are read before the job
    /// starts and the guard runs inside the job. The exception must call the guard's handler, which
    /// puts the slots back before the catch runs. A second handler, added by hand inside the guarded
    /// frame, only records if the runtime accepted it and called it: the failure text gives both.
    @available(macOS 26, *)
    @Test func theGuardPutsTheSlotsBackWhenARaiseLeavesTheJob() async {
        let state = await onFreshThread { () -> RaiseOutcome in
            let box = JobFactsBox()
            let before = SwiftExecutorFrames.Slots.current()
            let caught = archiveCatches {
                let outer = SwiftExecutorFrames.Slots.current()
                _ = Task.immediate {
                    let onUnwind: @Sendable () -> Void = { box.facts.withLock { $0.guardUnwound = true } }
                    SwiftExecutorFrames.guardingUnwind("test", restoring: outer, onUnwind: onUnwind) {
                        let token = objc_addExceptionHandler(markHandUnwind, Unmanaged.passUnretained(box).toOpaque())
                        box.facts.withLock {
                            $0.hadRecord = SwiftExecutorFrames.activeRecord() != nil
                            $0.handRegistered = token != 0
                        }
                        raiseObjectiveCException()
                        box.facts.withLock { $0.ranPastRaise = true }
                    }
                }
            }
            return RaiseOutcome.readAndClear(before: before, caught: caught, box: box)
        }
        let hand = "a handler added by hand: registered \(state.facts.handRegistered), called \(state.facts.handUnwound)"
        #expect(state.before == SwiftExecutorFrames.Slots(record: 0, task: 0))
        #expect(state.caught, "the archive call must catch the exception above the job frame")
        #expect(state.facts.hadRecord, "Task.immediate runs inline on the calling thread with a record set")
        #expect(!state.facts.ranPastRaise)
        #expect(state.facts.guardUnwound, "the guard's handler did not run; \(hand)")
        #expect(state.after == state.before, "slots after the catch: \(state.after); \(hand)")
        #expect(state.dead == nil, "slots after the catch: \(state.after); \(hand)")
    }
}

/// What the job saw before the exception, and which handlers the exception called.
nonisolated private struct JobFacts: Sendable {
    var hadRecord = false
    var ranPastRaise = false
    var guardUnwound = false
    var handRegistered = false
    var handUnwound = false
}

/// The facts of one case, shared between its job, its handlers and its thread.
nonisolated private final class JobFactsBox: Sendable {
    let facts = OSAllocatedUnfairLock(initialState: JobFacts())
}

/// The thread's state after the archive call returned.
nonisolated private struct RaiseOutcome: Sendable {
    let before: SwiftExecutorFrames.Slots
    let after: SwiftExecutorFrames.Slots
    let dead: UInt?
    let caught: Bool
    let facts: JobFacts

    /// Reads the slots as the exception left them, then empties them: the thread must not end with
    /// a record that a later frame can read.
    static func readAndClear(before: SwiftExecutorFrames.Slots, caught: Bool, box: JobFactsBox) -> RaiseOutcome {
        let after = SwiftExecutorFrames.Slots.current()
        let dead = SwiftExecutorFrames.deadRecord()
        SwiftExecutorFrames.Slots(record: 0, task: 0).install()
        return RaiseOutcome(before: before, after: after, dead: dead, caught: caught, facts: box.facts.withLock { $0 })
    }
}

/// Raises an Objective-C exception through the frames that call it.
nonisolated private func raiseObjectiveCException() {
    let name = NSExceptionName("SwiftExecutorFramesRaiseTests")
    NSException(name: name, reason: "raised inside a Swift job frame", userInfo: nil).raise()
}

/// The handler added by hand: the Objective-C runtime calls it when an exception thrown inside the
/// frame that added it is caught outside that frame. It changes no slot.
nonisolated private let markHandUnwind: objc_exception_handler = { _, context in
    guard let context else { return }
    Unmanaged<JobFactsBox>.fromOpaque(context).takeUnretainedValue().facts.withLock { $0.handUnwound = true }
}

/// An object whose `encode(with:)` runs `work`, so `work` runs below Foundation's Objective-C catch.
/// The archive writes the class name: a private class needs a fixed Objective-C name.
@objc(CmuxNextRaisingCoderForExecutorFramesTests)
nonisolated private final class RaisingCoder: NSObject, NSCoding {
    private let work: @Sendable () -> Void

    init(work: @escaping @Sendable () -> Void) {
        self.work = work
        super.init()
    }

    required init?(coder: NSCoder) {
        return nil
    }

    func encode(with coder: NSCoder) {
        work()
    }
}

/// Archives an object whose `encode(with:)` runs `work`. Returns true when the archive call caught
/// an Objective-C exception from `work` and reported it as an error.
@inline(never)
nonisolated private func archiveCatches(_ work: @escaping @Sendable () -> Void) -> Bool {
    do {
        _ = try NSKeyedArchiver.archivedData(withRootObject: RaisingCoder(work: work), requiringSecureCoding: false)
        return false
    } catch {
        return true
    }
}

/// Runs `body` on a new thread and returns its result.
nonisolated private func onFreshThread<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
    await withCheckedContinuation { continuation in
        Thread { continuation.resume(returning: body()) }.start()
    }
}
