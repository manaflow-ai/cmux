import AppKit
import CmuxNextDesign
@testable import CmuxNextLayout
import QuartzCore
import Testing

/// Cmd-D in a real window that is ordered in (a window on no screen does not animate): the new pane fades in on its
/// layers and nothing else moves (plans/cmux-next/motion-first-principles.md). The windows need a GUI session, so the
/// suite runs with the pane bench (CMUX_PANE_BENCH=1, scripts/measure/split-spring.sh --suite=pane-bench).
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["CMUX_PANE_BENCH"] == "1"))
struct SplitFadeWindowTests {
    typealias Split = SplitRenderMotionTests.Split

    private func keyPaths(_ layer: CALayer?) -> Set<String> {
        guard let layer else { return [] }
        return Set((layer.animationKeys() ?? []).compactMap { (layer.animation(forKey: $0) as? CAPropertyAnimation)?.keyPath })
    }

    /// Runs `body` with the panes gate moving (or with `disabled` off), Reduce Motion pinned off.
    private func with(disabled: Set<MotionCategory> = [], _ body: () throws -> Void) rethrows {
        let design = DesignSettings.shared
        let (oldDisabled, oldSpeed) = (design.disabledAnimationCategories, design.animationSpeed)
        Motion.reduceMotionOverride = false
        design.animationSpeed = .fast
        design.disabledAnimationCategories = disabled
        defer {
            design.disabledAnimationCategories = oldDisabled
            design.animationSpeed = oldSpeed
            Motion.reduceMotionOverride = nil
        }
        try body()
    }

    @Test(arguments: [false, true])
    func theNewPaneFadesOnItsLayersAndNothingMoves(renderServer: Bool) throws {
        try with {
            let split = Split(renderServer: renderServer)
            defer { split.close() }
            split.root.context.splitArrival = { .fade }
            split.split()
            let screen = split.screen
            let added = try split.host("b"), kept = try split.host("a")
            // One layout pass, at rest: no CPU spring and no render-server move.
            #expect(!screen.hasMotion, "a pane frame springs")
            for pane: PaneID in ["a", "b"] {
                let frame = try #require(screen.paneFrames[pane])
                #expect(frame.rect == frame.targetRect, "\(pane) is not at rest")
            }
            #expect(keyPaths(added.layer) == ["opacity"], "the new pane animates \(keyPaths(added.layer))")
            #expect(keyPaths(added.chrome.layer).isSubset(of: ["opacity"]), "the new pane's chrome animates \(keyPaths(added.chrome.layer))")
            #expect(keyPaths(kept.layer).isEmpty, "the split pane animates \(keyPaths(kept.layer))")
            #expect(added.alphaValue == 1 && added.layer?.opacity == 1, "the model opacity left its rest")
            for (kind, view) in screen.dividerViews {
                #expect(keyPaths(view.layer).isEmpty, "divider \(kind) animates")
            }
        }
    }

    /// The panes category off: the split shows in one frame, nothing animates.
    @Test func withThePanesCategoryOffTheSplitShowsInOneFrame() throws {
        try with(disabled: [.panes]) {
            let split = Split(renderServer: false)
            defer { split.close() }
            split.root.context.reduceMotionOverride = nil
            split.root.context.splitArrival = { .fade }
            split.split()
            #expect(keyPaths(try split.host("b").layer).isEmpty)
            #expect(!split.screen.hasMotion)
        }
    }
}
