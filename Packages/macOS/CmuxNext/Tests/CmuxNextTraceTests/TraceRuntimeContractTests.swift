@testable import CmuxNextTrace
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
        runtime.write(name: 1, categoryBit: 4, phase: .instant)
        #expect(runtime.stubRecordCount.load(ordering: .relaxed) == 0)
        runtime.write(name: 1, categoryBit: 3, phase: .instant)
        #expect(runtime.stubRecordCount.load(ordering: .relaxed) == 1)
        #expect(runtime.recordingStatus == .idle)
    }

    @Test("An interned name records only while its category is on")
    func internedNameGate() {
        let runtime = TraceRuntime(role: .app)
        let name = TraceRuntime.InternedName("test.site", categoryBit: 12)
        runtime.write(name, phase: .instant, arg0: 1)
        #expect(runtime.stubRecordCount.load(ordering: .relaxed) == 0)
        runtime.setCategoryMask(1 << 12)
        runtime.write(name, phase: .instant, arg0: 2)
        #expect(runtime.stubRecordCount.load(ordering: .relaxed) == 1)
    }

    /// trace.md "Release trace ring v1": the header's role table and Chrome's ASCII phase codes. Rust's
    /// `cmux-trace/tests/shared_values.rs` pins the same numbers.
    @Test("Roles, phases and flags keep the byte values the Rust and C writers use")
    func sharedByteValues() {
        let roles: [(TraceRuntime.Role, UInt16)] = [
            (.app, 1), (.daemon, 2), (.holder, 3), (.terminalHost, 4), (.acpmux, 5), (.chromiumHost, 6), (.cli, 7),
            (.agentHost, 8), (.appHost, 9), (.browserHost, 10),
        ]
        for (role, raw) in roles { #expect(role.rawValue == raw, "\(role)") }
        #expect(TraceRuntime.Role.allCases.count == roles.count)
        let phases: [(TraceRuntime.Phase, UInt8)] = [
            (.begin, 0x42), (.end, 0x45), (.instant, 0x49), (.asyncBegin, 0x62), (.asyncEnd, 0x65),
            (.flowOut, 0x73), (.flowIn, 0x66), (.counter, 0x43),
        ]
        for (phase, raw) in phases { #expect(phase.rawValue == raw, "\(phase)") }
        #expect(TraceRuntime.Phase.allCases.count == phases.count)
        #expect(TraceRuntime.RecordFlags.asyncID.rawValue == 1)
        #expect(TraceRuntime.RecordFlags.estimated.rawValue == 2)
        #expect(HangWatch.ThreadKind.allCases.map(\.rawValue) == Array(UInt8(1)...6))
    }

    @Test("Every crash-key slot keeps its word in the page")
    func crashKeySlotWordsArePinned() {
        let pinned: [(CrashKeySlot, UInt16)] = [
            (.actionIndex, 8), (.actionEntrypoint, 9), (.mainTaskOwner, 10), (.inCEFPump, 11), (.lastInputUptime, 12),
            (.windowCount, 13), (.workspaceCount, 14), (.terminalCount, 15), (.chromiumBrowserCount, 16),
            (.webKitViewCount, 17), (.daemonPID, 18), (.daemonState, 19), (.cefAPIVersion, 20), (.ghosttyCommit, 21),
            (.hangInProgressStart, 22), (.hangInProgressFrameCount, 23), (.hangInProgressImages, 24),
            (.hangInProgressFrames, 56), (.unclosedAgentPaneMaker, 120),
        ]
        for (slot, word) in pinned { #expect(slot.rawValue == word, "\(slot)") }
        #expect(CrashKeySlot.allCases.count == pinned.count)
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
