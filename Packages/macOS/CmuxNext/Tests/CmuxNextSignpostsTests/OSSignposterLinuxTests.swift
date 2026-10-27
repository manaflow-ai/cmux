// Where `os` does not exist (Linux), the signpost types are this module's no-ops (Platform/OSSignposter+Linux.swift)
// and the MetricKit mirror mirrors nothing. On macOS this file is empty: the system types are tested by the rest of
// the suite.

#if !canImport(os)
import CmuxNextCompat
@testable import CmuxNextSignposts
import CmuxNextSignpostsC
@testable import CmuxNextTrace
import Testing

/// Counts how often a message's value is read.
private final class Reads: Sendable {
    private let count = Atomic<Int>(0)

    var value: Int { count.load(ordering: .relaxed) }

    /// Reads once: the message would be built.
    func read() -> Int {
        count.add(1, ordering: .relaxed).newValue
    }
}

struct OSSignposterLinuxTests {
    private let signposter = OSSignposter(subsystem: SignpostCategory.subsystem, category: SignpostCategory.action.rawValue)

    @Test("Nothing takes the signposts, and no message is ever built")
    func emitsNothingAndBuildsNoMessage() {
        let reads = Reads()
        #expect(!signposter.isEnabled)
        let state = signposter.beginInterval("action.perform", id: signposter.makeSignpostID(), "n=\(reads.read(), privacy: .public)")
        signposter.endInterval("action.perform", state, "n=\(reads.read(), privacy: .public)")
        signposter.emitEvent("launch.mark", "n=\(reads.read(), privacy: .public)")
        signposter.emitEvent("launch.mark", id: .exclusive, "n=\(reads.read(), privacy: .public)")
        #expect(reads.value == 0)
    }

    @Test("Ids are unique, never null, invalid or exclusive, and shared with the C emitters' counter")
    func idsAreUniqueAcrossTheSwiftAndCEmitters() {
        var ids: [UInt64] = []
        for _ in 0..<100 {
            ids.append(signposter.makeSignpostID().rawValue)
            ids.append(cmux_signpost_key_frame_id())
            ids.append(cmux_signpost_stall_task_id())
        }
        #expect(Set(ids).count == ids.count)
        let reserved: Set<UInt64> = [OSSignpostID.null.rawValue, OSSignpostID.invalid.rawValue, OSSignpostID.exclusive.rawValue]
        #expect(reserved.isDisjoint(with: ids))
    }

    @Test("An interval's state carries the id it began with, as an end with no begin state rebuilds it")
    func intervalStateCarriesItsID() {
        let id = OSSignpostID(0x636D_7578_0000_0021)
        #expect(signposter.beginInterval("launch.ghostty_init", id: id).signpostID == id)
        #expect(OSSignpostIntervalState.beginState(id: id).signpostID == id)
    }

    @Test("With the mirror switched on, no interval is mirrored: there is no MetricKit")
    func theMirrorMirrorsNothing() {
        let mirror = SignpostMetricKitMirror()
        mirror.setOn(true)
        #expect(mirror.isOn)
        #expect(mirror.begin(.actionPerform) == nil)
        let action = Signposter(category: .action, mirror: mirror, trace: TraceRuntime(role: .app))
        let interval = action.begin(.actionPerform, "id=test")
        #expect(!interval.isMirrored)
        action.end(.actionPerform, interval)
    }

    @Test("Two overlapping async intervals of one name get distinct ring ids from the signposter")
    func overlappingIntervalsKeepDistinctRingIDs() throws {
        let runtime = TraceRuntime(role: .app)
        runtime.setCategoryMask(1 << UInt64(SignpostCategory.action.traceBit))
        let action = Signposter(category: .action, mirror: SignpostMetricKitMirror(), trace: runtime)
        let message = ActionSignpostMessage(id: "test.action", origin: "user", inputAgeMilliseconds: 1)
        let first = action.begin(.actionCommit, message)
        let second = action.begin(.actionCommit, message)
        guard case .async(let firstID)? = first.ring, case .async(let secondID)? = second.ring else {
            Issue.record("action.commit is an async slice: \(String(describing: first.ring)), \(String(describing: second.ring))")
            return
        }
        #expect(firstID != secondID)
        action.end(.actionCommit, second, .committed)
        action.end(.actionCommit, first, .committed)
    }
}
#endif
