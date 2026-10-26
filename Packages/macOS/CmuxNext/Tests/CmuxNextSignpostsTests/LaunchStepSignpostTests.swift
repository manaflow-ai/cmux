import CmuxNextCompat
@testable import CmuxNextSignposts
@testable import CmuxNextTrace
import Testing

/// The launch steps the daemon, agent pane and Ghostty runtime timings mark, and the `stall.create_surface` interval
/// of `TerminalTimings` (p09-observability task 035): both go through ``Signposter``, not a private `OSSignposter`.
struct LaunchStepSignpostTests {
    private let mirror = SignpostMetricKitMirror()

    private func text(_ name: StaticString) -> String {
        name.withUTF8Buffer { String(decoding: $0, as: UTF8.self) }
    }

    private func everyCategory(_ runtime: TraceRuntime) {
        runtime.setCategoryMask(SignpostCategory.allCases.reduce(UInt64(0)) { $0 | 1 << UInt64($1.traceBit) })
    }

    @Test("Launch step names are distinct, sit in the launch category and are not catalog names")
    func namesSitInTheLaunchCategory() {
        let names = Signposter.LaunchStepSource.allCases.map { text($0.name) }
        #expect(Set(names).count == Signposter.LaunchStepSource.allCases.count)
        #expect(names.allSatisfy { $0.hasPrefix("\(SignpostCategory.launch.rawValue).") })
        let catalog = Set(SignpostName.allCases.map(\.description))
        #expect(names.allSatisfy { !catalog.contains($0) }, "\(names)")
    }

    @Test("A launch step writes no trace ring record, with every category on")
    func aStepWritesNoRingRecord() {
        let runtime = TraceRuntime(role: .app)
        everyCategory(runtime)
        let launch = Signposter(category: .launch, mirror: mirror, trace: runtime)
        for source in Signposter.LaunchStepSource.allCases { launch.launchStep(source, "test.step") }
        #expect(runtime.stubRecordCount.load(ordering: .relaxed) == 0)
    }

    @Test("stall.create_surface is a stall thread slice: one begin and one end in the ring")
    func createSurfaceIsAThreadSlice() {
        #expect(SignpostName.stallCreateSurface.traceCategory == .stall)
        #expect(SignpostName.stallCreateSurface.opensThreadSlice)
        let runtime = TraceRuntime(role: .app)
        everyCategory(runtime)
        let stall = Signposter(category: .stall, mirror: mirror, trace: runtime)
        let interval = stall.begin(.stallCreateSurface)
        #expect(interval.ring == .thread)
        #expect(stall.nowNanos() >= interval.beginUptimeNanos)
        stall.end(.stallCreateSurface, interval)
        #expect(runtime.stubRecordCount.load(ordering: .relaxed) == 2)
    }
}
