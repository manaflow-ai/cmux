import AppKit
import Atomics
@testable import CmuxNextInput
import CmuxNextInputCore
import CmuxNextSignposts
import CmuxNextWakeups
import CoreFoundation
import Darwin
import Testing

/// DIAGNOSTIC (probe branch only, never merged): the allocations of each stage of the allocation rig's tracked turn.
@MainActor
@Suite(.serialized) struct InputLatencyStageProbeTests {
    @Test("Allocations per stage of a tracked turn")
    func stageAllocations() throws {
        let rig = try InputLatencyTrackerTests.AllocationRig()
        defer { rig.invalidate() }
        for _ in 0..<3 { rig.trackedTurn() }
        let timestamp = TimeInterval(InputLatencyTracker.uptimeNanos()) / 1e9
        let keyEvent = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                                     timestamp: timestamp, windowNumber: 0, context: nil,
                                                     characters: "a", charactersIgnoringModifiers: "a",
                                                     isARepeat: false, keyCode: 0))
        let mode = InputLatencyTrackerTests.AllocationRig.mode
        let turns = 20
        var begin = 0, began = 0, interpret = 0, endDispatch = 0, ended = 0, submit = 0, turn = 0, frame = 0
        var idleHold = 0, idleTurn = 0, idleFrame = 0, hold = 0, trace = 0, message = 0, table = 0, uptime = 0
        var frameTime = 5000.0
        for _ in 0..<turns {
            for index in 0..<64 {
                let target: InputTarget = index.isMultiple(of: 2) ? .textView : .terminal
                var opened: InputLatencyToken?
                begin += StageProbe.count {
                    opened = rig.tracker.begin(kind: .keyPress, target: target, entrypoint: .person,
                                               eventTimestamp: timestamp, window: rig.window)
                }
                guard let token = opened else { continue }
                var outer: TextInputStage.KeyDown?
                began += StageProbe.count { outer = rig.textInput.keyDownDispatchBegan(token, timestamp: timestamp) }
                interpret += StageProbe.count { rig.textInput.interpreting(keyEvent) {} }
                endDispatch += StageProbe.count { rig.tracker.endDispatch(token) }
                ended += StageProbe.count { rig.textInput.keyDownDispatchEnded(restoring: outer) }
                if target == .terminal { submit += StageProbe.count { rig.tracker.mark(token, .contentSubmitted) } }
            }
            turn += StageProbe.count { _ = CFRunLoopRunInMode(mode, 0, false) }
            frameTime += 1.0 / 60
            let time = frameTime
            frame += StageProbe.count {
                rig.scheduler.frameDidFire(timestamp: time, refreshInterval: 1.0 / 60, targetTimestamp: time + 1.0 / 60)
            }
        }
        for _ in 0..<turns {
            idleHold += StageProbe.count { rig.clock.holdForInput(on: rig.scheduler) }
            idleTurn += StageProbe.count { _ = CFRunLoopRunInMode(mode, 0, false) }
            frameTime += 1.0 / 60
            let time = frameTime
            idleFrame += StageProbe.count {
                rig.scheduler.frameDidFire(timestamp: time, refreshInterval: 1.0 / 60, targetTimestamp: time + 1.0 / 60)
            }
        }
        var slot = InputLatencySlot(kind: .keyPress, target: .textView, entrypoint: .person)
        slot.generated = 1_000
        slot.dispatchStart = 2_000
        slot.presented = 9_000_000
        let slotTable = InputLatencySlotTable()
        for _ in 0..<(turns * 64) {
            hold += StageProbe.count { rig.clock.holdLinkForInput(in: rig.window) }
            trace += StageProbe.count { InputLatencyTracker.tracePoint(InputLatencySignpostMessage(slot: slot), slot: slot) }
            message += StageProbe.count { _ = InputLatencySignpostMessage(slot: slot) }
            uptime += StageProbe.count { _ = InputLatencyTracker.uptimeNanos() }
            table += StageProbe.count {
                if let token = slotTable.begin(kind: .keyPress, target: .textView, entrypoint: .person, generated: 1_000) {
                    slotTable.mark(token, .dispatchStart, at: 2_000)
                    _ = slotTable.close(token)
                }
            }
        }
        let report = "STAGEPROBE turns=\(turns) events/turn=64 begin=\(begin) began=\(began) interpret=\(interpret) "
            + "endDispatch=\(endDispatch) ended=\(ended) submit=\(submit) turn=\(turn) frame=\(frame) "
            + "idleHold=\(idleHold) idleTurn=\(idleTurn) idleFrame=\(idleFrame) | isolated x\(turns * 64): "
            + "holdLinkForInput=\(hold) tracePoint=\(trace) message=\(message) uptime=\(uptime) table=\(table) "
            + "closed=\(rig.closed.value)"
        print(report)
        Issue.record(Comment(rawValue: report))
    }
}

private nonisolated struct StageProbe {
    typealias Logger = @convention(c) (UInt32, UInt, UInt, UInt, UInt, UInt32) -> Void

    static let allocateType: UInt32 = 2
    static let counter = ManagedAtomic<Int>(0)
    static let thread = ManagedAtomic<UInt64>(0)

    /// The allocations `body` makes on this thread, or a large negative number when the hook is missing.
    static func count(_ body: () -> Void) -> Int {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "malloc_logger") else { return -1_000_000 }
        let slot = symbol.assumingMemoryBound(to: Logger?.self)
        var id: UInt64 = 0
        pthread_threadid_np(nil, &id)
        counter.store(0, ordering: .relaxed)
        thread.store(id, ordering: .relaxed)
        let previous = slot.pointee
        slot.pointee = { type, _, _, _, _, _ in
            guard type & StageProbe.allocateType != 0 else { return }
            var id: UInt64 = 0
            pthread_threadid_np(nil, &id)
            if id == StageProbe.thread.load(ordering: .relaxed) { StageProbe.counter.wrappingIncrement(ordering: .relaxed) }
        }
        body()
        slot.pointee = previous
        thread.store(0, ordering: .relaxed)
        return counter.load(ordering: .relaxed)
    }
}
