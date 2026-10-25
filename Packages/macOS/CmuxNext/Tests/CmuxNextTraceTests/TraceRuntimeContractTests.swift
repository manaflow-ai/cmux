import CmuxNextTrace
import Testing

/// The frozen API of CmuxNextTrace (task 000): the values the Rust and C writers share, and the stubs'
/// contract. The ring, the crash-key page and the slot table get their own suites with their tasks.
@Suite("Trace runtime contract")
struct TraceRuntimeContractTests {
    @Test("The category mask gates each bit on its own")
    func categoryMask() {
        let runtime = TraceRuntime(role: .daemon)
        #expect(runtime.categoryMask == 0)
        #expect(!runtime.isEnabled(categoryBit: 3))
        runtime.setCategoryMask(1 << 3 | 1 << 63)
        #expect(runtime.isEnabled(categoryBit: 3))
        #expect(runtime.isEnabled(categoryBit: 63))
        #expect(!runtime.isEnabled(categoryBit: 4))
        runtime.write(name: 1, categoryBit: 3, phase: .instant)
        #expect(runtime.recordingStatus == .idle)
    }

    @Test("Roles, phases and flags keep the byte values the Rust and C writers use")
    func sharedByteValues() {
        #expect(TraceRuntime.Role.allCases.map(\.rawValue) == Array(UInt8(1)...9))
        #expect(TraceRuntime.Phase.allCases.map(\.rawValue) == Array(UInt8(1)...8))
        #expect(TraceRuntime.RecordFlags.asyncID.rawValue == 1)
        #expect(TraceRuntime.RecordFlags.estimated.rawValue == 2)
        #expect(HangWatch.ThreadKind.allCases.map(\.rawValue) == Array(UInt8(1)...6))
    }

    @Test("Crash-key slots do not overlap and fit the page after its header")
    func crashKeySlotsFit() {
        let slots = CrashKeySlot.allCases.sorted { $0.rawValue < $1.rawValue }
        #expect(slots.first.map { Int($0.rawValue) } == CrashKeySlot.headerWordCount)
        for (slot, next) in zip(slots, slots.dropFirst()) {
            #expect(Int(slot.rawValue) + slot.wordCount == Int(next.rawValue), "\(slot) runs into \(next)")
        }
        let last = slots[slots.count - 1]
        #expect(Int(last.rawValue) + last.wordCount <= CrashKeySlot.pageWordCount)
        let names = slots.map { "\($0.name)" }
        #expect(Set(names).count == names.count)
    }

    @Test("A hang-watch scope runs its body and nests")
    func hangWatchScopes() {
        let watch = HangWatch()
        let lane = watch.registerLane("test-lane")
        let thread = watch.registerThread(.io, name: "test-io")
        let value = watch.watch(lane, deadline: .seconds(1)) {
            watch.watch(thread, deadline: .milliseconds(250)) { 7 }
        }
        #expect(value == 7)
        let scope = watch.watch(thread)
        watch.invalidateActive()
        scope.close()
        watch.unregister(thread)
        watch.unregister(lane)
    }
}
