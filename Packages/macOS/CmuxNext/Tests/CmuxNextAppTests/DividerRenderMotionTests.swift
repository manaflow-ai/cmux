import AppKit
import CmuxNextDesign
@testable import CmuxNextLayout
import QuartzCore
import Testing

/// Dividers as layers (`motion.renderServer` on): a split's divider gets
/// its rest frame once in the key's turn, through the one placement path (`ScreenDividers.place`), and
/// springs on the render server with the panes' token, its line with it; nothing sets its frame again
/// before it lands. It takes no hover and shows no resize cursor mid-spring, and its landing alone hovers it
/// from a fresh hit test at its rest frame. A split whose turn also moves a camera on the CPU stays there.
///
/// Uses the real ordered-in windows of ``SplitRenderMotionTests`` (a window on no screen does not animate),
/// so it runs with the pane bench (CMUX_PANE_BENCH=1, scripts/measure/split-spring.sh --suite=pane-bench).
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["CMUX_PANE_BENCH"] == "1"))
struct DividerRenderMotionTests {
    typealias Split = SplitRenderMotionTests.Split

    static let divider = DividerHandleView.Kind.split(SplitID("d"))

    /// a | b, split at the middle.
    static let halves: SplitNode = .split(SplitID("d"), axis: .horizontal, ratio: 0.5, a: .leaf("a"), b: .leaf("b"))
    /// Cmd-D on b with even sizing: three equal columns, so divider d moves from the middle to a third.
    static let thirds: SplitNode = .split(SplitID("d"), axis: .horizontal, ratio: 1.0 / 3, a: .leaf("a"),
                                          b: .split(SplitID("e"), axis: .horizontal, ratio: 0.5, a: .leaf("b"), b: .leaf("c")))

    /// The rest frame of divider `kind` in the screen: where its spring lands.
    static func rest(_ split: Split, _ kind: DividerHandleView.Kind = divider) throws -> CGRect {
        let screen = split.screen
        let frame = try #require(screen.dividerFrames[kind])
        return screen.shownRect(frame.targetRect, of: kind, strip: screen.stripShift, scale: screen.scale)
    }

    @Test func aSplitsDividerIsSetToRestOnceAndSpringsWithThePanes() async throws {
        try await SplitRenderMotionTests.withMotion {
            let split = Split(renderServer: true, layout: .splits(Self.halves))
            defer { split.close() }
            try #require(split.window.screen != nil, "the window is on no screen: nothing animates")
            let screen = split.screen
            let view = try #require(screen.dividerViews[Self.divider])
            let layer = try #require(view.layer)
            let before = view.frame
            let frameSets = view.frameSetCount
            split.split(Self.thirds)
            let rest = try Self.rest(split)
            #expect(abs(rest.midX - before.midX) > 100, "divider d does not move: \(before) to \(rest)")
            #expect(view.isOnRenderSpring, "the divider is not on the render server")
            #expect(view.frame == rest, "the divider is not at rest after the key's turn")
            #expect(view.frameSetCount == frameSets + 1, "\(view.frameSetCount - frameSets) divider frame sets in the key's turn, not 1")
            #expect(layer.frame == view.frame, "the divider's layer frame is not its frame: its springs start in the wrong place")
            #expect(view.placedClips != nil, "the divider's start did not place its clips")
            #expect(!(layer.animationKeys() ?? []).isEmpty, "the divider's layer has no render-server spring")
            let paneLayer = try #require(split.host("a").layer)
            #expect(!(paneLayer.animationKeys() ?? []).isEmpty, "the panes beside it do not spring with it")
            #expect(await split.landed(), "the split did not land in 5 s")
            #expect(view.frameSetCount == frameSets + 1,
                    "\(view.frameSetCount - frameSets - 1) divider frame sets between start and landing")
            #expect(!view.isOnRenderSpring)
            #expect(view.frame == rest)
            #expect(!split.root.driver.isRunning, "the divider's landing asked for layout frames")
        }
    }

    /// [a | (b1 / b2)], Cmd-D on a: three equal columns, so the b1/b2 divider gets shorter as it moves.
    @Test func aDividerWhoseLengthChangesDrawsItsLineAlongWhatItShows() async throws {
        try await SplitRenderMotionTests.withMotion {
            let stack: SplitNode = .split(SplitID("f"), axis: .vertical, ratio: 0.5, a: .leaf("b1"), b: .leaf("b2"))
            let split = Split(renderServer: true,
                              layout: .splits(.split(SplitID("d"), axis: .horizontal, ratio: 0.5, a: .leaf("a"), b: stack)))
            defer { split.close() }
            try #require(split.window.screen != nil, "the window is on no screen: nothing animates")
            let clock = try #require(split.root.layer)
            SplitRenderMotionTests.freeze(clock)
            split.split(.split(SplitID("d"), axis: .horizontal, ratio: 2.0 / 3,
                               a: .split(SplitID("g"), axis: .horizontal, ratio: 0.5, a: .leaf("a"), b: .leaf("c")), b: stack))
            let kind = DividerHandleView.Kind.split(SplitID("f"))
            let view = try #require(split.screen.dividerViews[kind])
            #expect(view.isOnRenderSpring, "the b1/b2 divider is not on the render server")
            let layer = try #require(view.layer)
            let line = view.lineLayer
            #expect(!(line.animationKeys() ?? []).isEmpty, "the divider's size springs but its line does not")
            let half = SplitRenderMotionTests.time(toProgress: 0.5, Motion.panes.spring(split.screen.motionState.frameSpring))
            let shown = try SplitRenderMotionTests.presented(layer, at: half, root: clock)
            let shownLine = try #require(line.presentation()).frame
            #expect(abs(shown.width - layer.bounds.width) > 50, "the divider's length does not change: \(shown) vs \(layer.bounds)")
            // The line is in the handle's coordinates: it spans the bounds the handle shows now.
            #expect(abs(shownLine.minX) <= 0.5 && abs(shownLine.width - shown.width) <= 0.5,
                    "the line shows \(shownLine) in a handle \(shown.width) wide half way")
        }
    }

    @Test func theLandingAloneHoversADividerThatSprangUnderThePointer() async throws {
        try await SplitRenderMotionTests.withMotion {
            let split = Split(renderServer: true, layout: .splits(Self.halves))
            defer { split.close() }
            try #require(split.window.screen != nil, "the window is on no screen: nothing animates")
            let screen = split.screen
            var pointer: CGPoint?
            split.root.context.hoverPointer = { _, _ in pointer.map { screen.convert($0, to: nil) } }
            split.root.context.hoverReachesWindow = { _, _ in true }
            let view = try #require(screen.dividerViews[Self.divider])
            pointer = CGPoint(x: view.frame.midX, y: view.frame.midY)
            screen.refreshDividerHover()
            try #require(view.isHovered, "the pointer on the divider does not hover it")
            split.split(Self.thirds)
            #expect(!view.isHovered, "the divider stays hovered while it springs away from the pointer")
            // The pointer follows to where the divider lands; no tracking event reaches the screen.
            let rest = try Self.rest(split)
            pointer = CGPoint(x: rest.midX, y: rest.midY)
            #expect(await split.landed(), "the split did not land in 5 s")
            #expect(view.isHovered, "the landing did not hover the divider under the pointer")
        }
    }

    @Test func theLandingHitTestsWhereThePointerIsNowNotWhereItWas() async throws {
        try await SplitRenderMotionTests.withMotion {
            let split = Split(renderServer: true, layout: .splits(Self.halves))
            defer { split.close() }
            try #require(split.window.screen != nil, "the window is on no screen: nothing animates")
            let screen = split.screen
            var pointer: CGPoint?
            split.root.context.hoverPointer = { _, _ in pointer.map { screen.convert($0, to: nil) } }
            split.root.context.hoverReachesWindow = { _, _ in true }
            let view = try #require(screen.dividerViews[Self.divider])
            split.split(Self.thirds)
            // A tracking event mid-spring at the rest frame: no hover while the divider shows elsewhere.
            let rest = try Self.rest(split)
            pointer = CGPoint(x: rest.midX, y: rest.midY)
            screen.refreshDividerHover()
            #expect(!view.isHovered, "the divider hovers at its rest frame while it shows elsewhere")
            // The pointer leaves with no event; the landing reads where it is now.
            pointer = CGPoint(x: rest.midX + 150, y: rest.midY)
            #expect(await split.landed(), "the split did not land in 5 s")
            #expect(!view.isHovered, "the landing hovered from the pointer of the last tracking event")
        }
    }

    /// Two viewport-wide strip columns, a then b; the split puts c beside b, in the column off screen. With
    /// the focus left on a it springs on the render server; with the focus on c the strip's camera reveals
    /// c on the CPU in the same turn, and the split stays on the CPU with it (each camera frame places every
    /// pane and divider at the camera's shift).
    @Test func aSplitThatMovesTheStripCameraStaysOnTheCPU() async throws {
        try await SplitRenderMotionTests.withMotion {
            let first = LayoutColumn(id: ColumnID("c1"), width: 1, root: .leaf("a"))
            let before = ScreenLayout.columns([first, LayoutColumn(id: ColumnID("c2"), width: 1, root: .leaf("b"))])
            let after = ScreenLayout.columns([first, LayoutColumn(id: ColumnID("c2"), width: 1, root: .split(
                SplitID("d"), axis: .horizontal, ratio: 0.5, a: .leaf("b"), b: .leaf("c")))])
            for focus: PaneID? in [nil, "c"] {
                let split = Split(renderServer: true, layout: before)
                defer { split.close() }
                try #require(split.window.screen != nil, "the window is on no screen: nothing animates")
                split.root.driver.isManual = true
                let screen = split.screen
                let offset = screen.scroll.target
                split.split(after, focus: focus)
                let view = try #require(screen.dividerViews[Self.divider])
                let host = try split.host("b")
                guard focus != nil else {
                    try #require(screen.scroll.target == offset, "the split moves the strip camera with the focus on a")
                    try #require(view.isOnRenderSpring && host.isOnRenderSpring, "a split with a still camera is not on the render server")
                    continue
                }
                try #require(screen.scroll.target != offset, "the split does not move the strip camera")
                #expect(!view.isOnRenderSpring, "the divider springs on the render server under a CPU camera")
                #expect(view.layer?.animationKeys()?.isEmpty ?? true, "the divider has render-server springs under a CPU camera")
                #expect(!host.isOnRenderSpring, "the panes spring on the render server under a CPU camera")
                #expect(screen.hasMotion, "the split does not spring on the CPU")
            }
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
