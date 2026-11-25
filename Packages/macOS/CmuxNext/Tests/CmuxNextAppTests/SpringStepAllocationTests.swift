import AppKit
@testable import CmuxNextApp
import CmuxNextCompat
import CmuxNextDesign
@testable import CmuxNextLayout
import Darwin
import Foundation
import Testing

/// HOT PATH AUDIT frames (motion-frame): one layout spring frame stepped every pane's and divider's spring through
/// `paneFrames[key]?.advanceUnsettled(...)`, an in-place mutation of a dictionary value. Each such call goes through
/// `Dictionary.subscript._modify`, a coroutine whose frame the runtime allocated on the heap (`swift_coroFrameAlloc`):
/// about 63 of the 180 main-thread allocations of a Release spring frame in a 12-pane grid (fleet job
/// 6bfa0edf7eda31d26fd3754e). Stepping the springs allocates at most the key lists now, not one frame per spring.
/// Counted in Release (CMUX_SWIFT_SUITE_CONFIGURATION=release), where the shipped code runs.
@MainActor @Suite(.serialized, .closesItsWindows)
struct SpringStepAllocationTests {
    @Test func steppingTheSpringsAllocatesNoCoroutineFramePerSpring() async throws {
        let columns = (0..<4).map { PaneMotionBench.column($0, rows: 3, width: 0.25) }
        let probe = LayoutWorkProbe(.columns(columns), focused: PaneID("p0-0"))
        defer { probe.close() }
        // Every column's first split moves: 12 panes and the row dividers spring.
        let next = (0..<4).map { index in
            var column = PaneMotionBench.column(index, rows: 3, width: 0.25)
            if case let .split(id, axis, _, a, b) = column.root { column.root = .split(id, axis: axis, ratio: 0.2, a: a, b: b) }
            return column
        }
        probe.model.apply(screens: [LayoutScreen(id: "s", name: "s", layout: .columns(next))])
        for _ in 0..<4 { await Task.yield() }
        let screen = probe.screen
        let springs = screen.paneFrames.count + screen.dividerFrames.count
        _ = screen.advancePaneAndDividerSprings(1.0 / 120, policy: Motion.panes.policy) // warm-up
        let control = SpringStepMalloc.allocations { _ = ContiguousArray(repeating: 1, count: 64).count }
        try #require((control ?? 0) > 0, "malloc_logger saw no allocation on this thread: the probe cannot measure here")
        let frames = 10
        let policy = Motion.panes.policy
        var moving = true
        let allocations = try #require(SpringStepMalloc.allocations {
            for _ in 0..<frames where moving { moving = screen.advancePaneAndDividerSprings(1.0 / 120, policy: policy) }
        })
        let perFrame = Double(allocations) / Double(frames)
        print("HPA-COUNT case=spring-step springs=\(springs) frames=\(frames) allocations=\(allocations) per_frame=\(String(format: "%.1f", perFrame))")
        try #require(springs >= 12)
        // The floor is the two key lists (one per spring kind); one allocation per spring is the defect. An unoptimized
        // build allocates in accessors and closures where an optimized one does not (56 per frame in Debug, fleet step
        // fa75e0c69d5b3961702cdad2), so the bound is the optimized build's rule (as KeyRouterBench); `#if DEBUG` is not
        // the optimization level (the Release suite lane also passes -DDEBUG).
        if _isDebugAssertConfiguration() {
            withKnownIssue("an unoptimized build allocates in accessors; run in Release for the rule", isIntermittent: true) {
                #expect(perFrame <= 4, "\(springs) springs stepped with \(String(format: "%.1f", perFrame)) allocations per frame")
            }
        } else {
            #expect(perFrame <= 4, "\(springs) springs stepped with \(String(format: "%.1f", perFrame)) allocations per frame")
        }
    }
}

private typealias SpringStepLogger = @convention(c) (UInt32, UInt, UInt, UInt, UInt, UInt32) -> Void

nonisolated private struct SpringStepTally {
    static let thread = Atomic<UInt32>(0)
    static let allocations = Atomic<Int>(0)
}

nonisolated private func tallySpringStep(type: UInt32, arg1: UInt, arg2: UInt, arg3: UInt, result: UInt, skip: UInt32) {
    guard type & 2 != 0, pthread_mach_thread_np(pthread_self()) == SpringStepTally.thread.load(ordering: .relaxed) else { return }
    _ = SpringStepTally.allocations.add(1, ordering: .relaxed)
}

nonisolated private struct SpringStepMalloc {
    static func allocations(_ body: () -> Void) -> Int? {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "malloc_logger") else { return nil }
        let hook = symbol.assumingMemoryBound(to: SpringStepLogger?.self)
        SpringStepTally.allocations.store(0, ordering: .relaxed)
        SpringStepTally.thread.store(pthread_mach_thread_np(pthread_self()), ordering: .relaxed)
        let previous = hook.pointee
        hook.pointee = tallySpringStep
        body()
        hook.pointee = previous
        SpringStepTally.thread.store(0, ordering: .relaxed)
        return SpringStepTally.allocations.load(ordering: .relaxed)
    }
}
