import AppKit
import CmuxNextDesign
@testable import CmuxNextLayout
import QuartzCore
import Testing

/// Dividers as layers (chrome-parity p03-rendering-024, `motion.renderServer` on): a split's divider gets
/// its rest frame once in the key's turn and springs on the render server with the panes' token; nothing
/// sets its frame again before it lands. It takes no hover and shows no resize cursor mid-spring, and its
/// landing hovers it from a fresh hit test at its rest frame.
///
/// Uses the real ordered-in windows of ``SplitRenderMotionTests`` (a window on no screen does not animate),
/// so it runs with the pane bench (CMUX_PANE_BENCH=1, scripts/measure/split-spring.sh --suite=pane-bench).
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["CMUX_PANE_BENCH"] == "1"))
struct DividerRenderMotionTests {
    typealias Split = SplitRenderMotionTests.Split

    static let divider = DividerHandleView.Kind.split(SplitID("d"))

    /// The divider's rest frame in the screen: where its spring lands.
    static func rest(_ split: Split) throws -> CGRect {
        let screen = split.screen
        let frame = try #require(screen.dividerFrames[divider])
        return screen.shownRect(frame.targetRect, of: divider, strip: screen.stripShift, scale: screen.scale)
    }

    @Test func aSplitsDividerIsSetToRestOnceAndSpringsWithThePanes() async throws {
        try await SplitRenderMotionTests.withMotion {
            let split = Split(renderServer: true)
            defer { split.close() }
            try #require(split.window.screen != nil, "the window is on no screen: nothing animates")
            split.split()
            let screen = split.screen
            let view = try #require(screen.dividerViews[Self.divider])
            let layer = try #require(view.layer)
            let rest = try Self.rest(split)
            #expect(view.isOnRenderSpring, "the divider is not on the render server")
            #expect(view.frame == rest, "the divider is not at rest after the key's turn")
            #expect(view.placedClips != nil, "the change turn's presentation did not place the divider's clips")
            #expect(!(layer.animationKeys() ?? []).isEmpty, "the divider's layer has no render-server spring")
            let paneLayer = try #require(split.host("a").layer)
            #expect(!(paneLayer.animationKeys() ?? []).isEmpty, "the panes beside it do not spring with it")
            let frameSets = view.frameSetCount
            #expect(await split.landed(), "the split did not land in 5 s")
            #expect(view.frameSetCount == frameSets, "\(view.frameSetCount - frameSets) divider frame sets between start and landing")
            #expect(!view.isOnRenderSpring)
            #expect(view.frame == rest)
            #expect(!split.root.driver.isRunning, "the divider's landing asked for layout frames")
        }
    }

    @Test func hoverWaitsForTheLandingAndIsAFreshHitTestThere() async throws {
        try await SplitRenderMotionTests.withMotion {
            let split = Split(renderServer: true)
            defer { split.close() }
            try #require(split.window.screen != nil, "the window is on no screen: nothing animates")
            let screen = split.screen
            var pointer: CGPoint?
            split.root.context.hoverPointer = { _, _ in pointer.map { screen.convert($0, to: nil) } }
            split.root.context.hoverReachesWindow = { _, _ in true }
            split.split()
            let view = try #require(screen.dividerViews[Self.divider])
            let rest = try Self.rest(split)
            // The pointer rests where the divider lands; the divider still shows near the right edge.
            pointer = CGPoint(x: rest.midX, y: rest.midY)
            screen.refreshDividerHover()
            #expect(!view.isHovered, "the divider hovers at its rest frame while it shows elsewhere")
            #expect(await split.landed(), "the split did not land in 5 s")
            #expect(view.isHovered, "the landing did not hover the divider under the pointer")
            // Fresh at the landing: a pointer that left during the spring leaves it unhovered.
            pointer = CGPoint(x: rest.midX + 200, y: rest.midY)
            screen.refreshDividerHover()
            #expect(!view.isHovered)
        }
    }

    @Test func aPointerThatLeftMidSpringLeavesTheLandedDividerUnhovered() async throws {
        try await SplitRenderMotionTests.withMotion {
            let split = Split(renderServer: true)
            defer { split.close() }
            try #require(split.window.screen != nil, "the window is on no screen: nothing animates")
            let screen = split.screen
            var pointer: CGPoint?
            split.root.context.hoverPointer = { _, _ in pointer.map { screen.convert($0, to: nil) } }
            split.root.context.hoverReachesWindow = { _, _ in true }
            split.split()
            let view = try #require(screen.dividerViews[Self.divider])
            let rest = try Self.rest(split)
            pointer = CGPoint(x: rest.midX, y: rest.midY)
            screen.refreshDividerHover()
            pointer = CGPoint(x: rest.midX - 200, y: rest.midY)
            #expect(await split.landed(), "the split did not land in 5 s")
            #expect(!view.isHovered, "the landing hovered from a stale pointer")
        }
    }

    @Test func offTheDividerStepsOnTheCPUAsBefore() async throws {
        try await SplitRenderMotionTests.withMotion {
            let split = Split(renderServer: false)
            defer { split.close() }
            split.root.driver.isManual = true
            split.split()
            let view = try #require(split.screen.dividerViews[Self.divider])
            #expect(!view.isOnRenderSpring)
            #expect(view.layer?.animationKeys()?.isEmpty ?? true, "the divider has render-server springs with the switch off")
            let frameSets = view.frameSetCount
            #expect(split.root.advanceFrame(1.0 / 120), "the CPU step has nothing to move")
            #expect(view.frameSetCount > frameSets, "the CPU step did not move the divider")
        }
    }
}
