import AppKit
@testable import CmuxNextApp
import CmuxNextCompat
@testable import CmuxNextLayout
import Darwin
import Foundation
import Testing

/// #35934 (ClosingPanes step B), paired A/B on cmux21: the 4x2 Chromium column-close row's layout p95 was 4.20/4.28/4.45 ms
/// on the head against 1.99/3.43/2.06 ms on the base, every round. `ClosingPanes.rects`, which the screen calls in each
/// layout pass of a close (`presentClosingPanes`), mapped the live frames into a fresh `FrameFact` array, then a fresh
/// `CmuxClosingFrame` array, a fresh answer array and a fresh dictionary: one heap allocation per step, and one more per
/// live frame for its velocity list. Each frame now reuses the buffers it kept from the last one, so the only allocation
/// left is the dictionary the screen reads (the review of #35934, item 3). Counted in Release
/// (CMUX_SWIFT_SUITE_CONFIGURATION=release), where the shipped code runs.
@MainActor @Suite(.serialized, .closesItsWindows)
struct ClosingPanesFrameAllocationTests {
    @Test func aCloseFramesRectsAllocateOnlyTheAnswer() throws {
        let columns = (0..<4).map { PaneMotionBench.column($0, rows: 2, width: 0.25) }
        let rig = PaneGroundCoversPaneTests.Rig(.columns(columns), focused: PaneID("p1-0"))
        defer { rig.close() }
        let screen = try rig.screen
        _ = try #require(rig.model.showPaneClose(PaneID("p1-0")), "SETUP: p1-0 did not close")
        rig.root.syncWithModel()
        rig.root.layoutSubtreeIfNeeded()
        _ = rig.frame()
        try #require(!screen.closingPanes.isEmpty, "SETUP: nothing is closing")
        try #require(screen.paneFrames.count >= 7, "SETUP: \(screen.paneFrames.count) live frames")
        let frames = screen.paneFrames
        let row = screen.rowScrollTravel
        let warm = screen.closingPanes.rects(frames: frames, row: row) // the Rust buffers and the kept ones grow here
        try #require(!warm.isEmpty, "SETUP: the closing pane has no rect")
        let control = ClosingRectsMalloc.allocations { _ = ContiguousArray(repeating: 1, count: 64).count }
        try #require((control ?? 0) > 0, "malloc_logger saw no allocation on this thread: the probe cannot measure here")
        let calls = 10
        var placed = 0
        let allocations = try #require(ClosingRectsMalloc.allocations {
            for _ in 0..<calls { placed += screen.closingPanes.rects(frames: frames, row: row).count }
        })
        let perFrame = Double(allocations) / Double(calls)
        print("HPA-COUNT case=closing-rects live=\(frames.count) placed=\(placed / calls) calls=\(calls) allocations=\(allocations) "
              + "per_frame=\(String(format: "%.1f", perFrame))")
        // The floor is the answer's dictionary. An unoptimized build allocates in accessors and closures where an optimized
        // one does not, so the bound is the optimized build's rule (as SpringStepAllocationTests).
        if _isDebugAssertConfiguration() {
            withKnownIssue("an unoptimized build allocates in accessors; run in Release for the rule", isIntermittent: true) {
                #expect(perFrame <= 1, "a close frame's rects allocated \(String(format: "%.1f", perFrame)) times for \(frames.count) live frames")
            }
        } else {
            #expect(perFrame <= 1, "a close frame's rects allocated \(String(format: "%.1f", perFrame)) times for \(frames.count) live frames")
        }
    }
}

private typealias ClosingRectsLogger = @convention(c) (UInt32, UInt, UInt, UInt, UInt, UInt32) -> Void

nonisolated private struct ClosingRectsTally {
    static let thread = Atomic<UInt32>(0)
    static let allocations = Atomic<Int>(0)
}

nonisolated private func tallyClosingRects(type: UInt32, arg1: UInt, arg2: UInt, arg3: UInt, result: UInt, skip: UInt32) {
    guard type & 2 != 0, pthread_mach_thread_np(pthread_self()) == ClosingRectsTally.thread.load(ordering: .relaxed) else { return }
    _ = ClosingRectsTally.allocations.add(1, ordering: .relaxed)
}

nonisolated private struct ClosingRectsMalloc {
    static func allocations(_ body: () -> Void) -> Int? {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "malloc_logger") else { return nil }
        let hook = symbol.assumingMemoryBound(to: ClosingRectsLogger?.self)
        ClosingRectsTally.allocations.store(0, ordering: .relaxed)
        ClosingRectsTally.thread.store(pthread_mach_thread_np(pthread_self()), ordering: .relaxed)
        let previous = hook.pointee
        hook.pointee = tallyClosingRects
        body()
        hook.pointee = previous
        ClosingRectsTally.thread.store(0, ordering: .relaxed)
        return ClosingRectsTally.allocations.load(ordering: .relaxed)
    }
}
