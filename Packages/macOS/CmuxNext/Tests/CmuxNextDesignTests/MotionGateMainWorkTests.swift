import AppKit
@testable import CmuxNextDesign
import CmuxNextDesignTokens
import QuartzCore
import Testing

/// p03-rendering-104: a layer-backed view's frame and alpha animate on the render server
/// (`MotionGate.set(_:frame:spring:)`, `set(_:frame:fade:)`, `set(_:alpha:fade:)`). The model is
/// written once, in the change's turn, and the main thread does nothing per frame. The probe does not
/// depend on how AppKit animates: it blocks the main thread mid-change and reads whether what is on
/// screen moved meanwhile (Chrome's compositor animations go on through main-thread jank the same way).
@MainActor @Suite(.serialized) struct MotionGateMainWorkTests {
    /// Counts the model writes that change the value (RenderStats' `frame_sets` rule: an equal set counts 0).
    final class CountingView: NSView {
        private(set) var frameWrites = 0
        private(set) var alphaWrites = 0

        override func setFrameOrigin(_ newOrigin: NSPoint) {
            if newOrigin != frame.origin { frameWrites += 1 }
            super.setFrameOrigin(newOrigin)
        }

        override func setFrameSize(_ newSize: NSSize) {
            if newSize != frame.size { frameWrites += 1 }
            super.setFrameSize(newSize)
        }

        override var alphaValue: CGFloat {
            get { super.alphaValue }
            set {
                if newValue != super.alphaValue { alphaWrites += 1 }
                super.alphaValue = newValue
            }
        }
    }

    @MainActor final class Flag {
        var raised = false
    }

    /// Runs `body` with every animation on (or all off) at speed "normal" (the longest), Reduce Motion
    /// pinned off, then puts the switches back. Synchronous: the switches are process-wide, so no other
    /// test runs while they are changed. A change started in `body` keeps its timing after it.
    private func withMotion<T>(enabled: Bool = true, _ body: () throws -> T) rethrows -> T {
        let design = DesignSettings.shared
        let (oldEnabled, oldDisabled, oldSpeed) = (design.animationsEnabled, design.disabledAnimationCategories, design.animationSpeed)
        Motion.reduceMotionOverride = false
        design.animationSpeed = .normal
        design.animationsEnabled = enabled
        design.disabledAnimationCategories = []
        defer {
            design.animationsEnabled = oldEnabled
            design.disabledAnimationCategories = oldDisabled
            design.animationSpeed = oldSpeed
            Motion.reduceMotionOverride = nil
        }
        return try body()
    }

    /// `view`, layer-backed, in an on-screen window: a change in a window with no screen applies at once.
    private func onScreen(_ view: NSView) throws -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 200, y: 300, width: 700, height: 240), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.contentView?.wantsLayer = true
        view.wantsLayer = true
        window.contentView?.addSubview(view)
        window.orderFrontRegardless()
        try #require(window.screen != nil)
        try #require(view.layer != nil)
        return window
    }

    /// Whether `shown` changes by more than `threshold` while the main thread is blocked for
    /// `milliseconds` right after the change commits. A render-server animation advances with main
    /// blocked; one stepped on the main thread waits for the next run-loop turn.
    private func advancesWithMainBlocked(for milliseconds: Int, threshold: CGFloat = 0.5, _ shown: () -> CGFloat?) -> Bool {
        CATransaction.flush()
        let before = shown()
        let end = ContinuousClock.now + .milliseconds(milliseconds)
        while ContinuousClock.now < end {} // The jank under test: no run-loop turn, so no main-thread frame.
        guard let before, let after = shown() else { return false }
        return abs(after - before) > threshold
    }

    private func keys(_ view: NSView, _ prefix: String, path: String = "") -> [String] {
        (view.layer?.animationKeys() ?? []).filter { $0.hasPrefix(path.isEmpty ? "\(prefix)." : "\(prefix).\(path).") }
    }

    private func shownX(_ view: NSView) -> CGFloat? { view.layer?.presentation()?.position.x }
    private func shownY(_ view: NSView) -> CGFloat? { view.layer?.presentation()?.position.y }

    // MARK: Render server: one model write, nothing per frame

    @Test(.enabled("needs an awake display and animations on") { await GUIAnimationTestSupport.animatesHere() })
    func aSpringMoveWritesTheFrameOnceAndMovesWithTheMainThreadBlocked() async throws {
        let view = CountingView(frame: NSRect(x: 0, y: 40, width: 80, height: 40))
        let window = try onScreen(view)
        defer { window.orderOut(nil) }
        let flag = Flag()
        let target = NSRect(x: 400, y: 100, width: 120, height: 60)
        let start = view.frameWrites
        withMotion { Motion.panes.set(view, frame: target, spring: .move, completion: { flag.raised = true }) }
        #expect(view.frame == target, "the model lands in the change's turn")
        let written = view.frameWrites - start
        #expect((1...2).contains(written), "one origin and one size write, not \(written)")
        #expect(keys(view, MotionGate.frameKey).count == 4, "one additive spring per changed component")
        #expect(advancesWithMainBlocked(for: 60) { shownX(view) }, "the move waits for the main thread")
        #expect(await GUIAnimationTestSupport.settle { flag.raised }, "the move never ended")
        #expect(view.frameWrites - start == written, "main wrote the frame again while it moved")
        #expect(keys(view, MotionGate.frameKey).isEmpty)
    }

    /// "…"'s slide (`PaneToolbarView.slideMore`): a short move on a fade token.
    @Test(.enabled("needs an awake display and animations on") { await GUIAnimationTestSupport.animatesHere() })
    func aFadeTimedSlideWritesTheFrameOnceAndMovesWithTheMainThreadBlocked() async throws {
        let view = CountingView(frame: NSRect(x: 100, y: 40, width: 24, height: 24))
        let window = try onScreen(view)
        defer { window.orderOut(nil) }
        let flag = Flag()
        let start = view.frameWrites
        withMotion {
            Motion.feedback.set(view, frame: NSRect(x: 140, y: 40, width: 24, height: 24), fade: .hover, completion: { flag.raised = true })
        }
        #expect(view.frameWrites - start == 1, "one origin write")
        #expect(keys(view, MotionGate.frameKey, path: "position.x").count == 1)
        #expect(keys(view, MotionGate.frameKey).count == 1, "only the changed component animates")
        #expect(advancesWithMainBlocked(for: 40) { shownX(view) }, "the slide waits for the main thread")
        #expect(await GUIAnimationTestSupport.settle { flag.raised }, "the slide never ended")
        #expect(view.frameWrites - start == 1, "main wrote the frame again while it slid")
    }

    @Test(.enabled("needs an awake display and animations on") { await GUIAnimationTestSupport.animatesHere() })
    func anAlphaFadeWritesAlphaOnceAndFadesWithTheMainThreadBlocked() async throws {
        let view = CountingView(frame: NSRect(x: 100, y: 40, width: 80, height: 40))
        let window = try onScreen(view)
        defer { window.orderOut(nil) }
        let flag = Flag()
        let start = view.alphaWrites
        withMotion { Motion.feedback.set(view, alpha: 0, fade: .fadeOut, completion: { flag.raised = true }) }
        #expect(view.alphaValue == 0, "the model lands in the change's turn")
        #expect(view.alphaWrites - start == 1)
        #expect(advancesWithMainBlocked(for: 40, threshold: 0.05) { view.layer?.presentation().map { CGFloat($0.opacity) } },
                "the fade waits for the main thread")
        #expect(await GUIAnimationTestSupport.settle { flag.raised }, "the fade never ended")
        #expect(view.alphaWrites - start == 1, "main wrote alpha again while it faded")
        #expect(keys(view, MotionGate.alphaKey).isEmpty)
    }

    /// A retarget mid-flight (perpendicular, so both axes change course) adds springs from the old
    /// model and keeps the running ones: what shows does not jump.
    @Test(.enabled("needs an awake display and animations on") { await GUIAnimationTestSupport.animatesHere() })
    func aRetargetMidFlightAddsSpringsAndShowsNoJump() throws {
        let view = CountingView(frame: NSRect(x: 0, y: 20, width: 80, height: 40))
        let window = try onScreen(view)
        defer { window.orderOut(nil) }
        let target = NSRect(x: 200, y: 160, width: 80, height: 40)
        let (before, after) = withMotion { () -> ((CGFloat?, CGFloat?), (CGFloat?, CGFloat?)) in
            Motion.panes.set(view, frame: NSRect(x: 400, y: 20, width: 80, height: 40), spring: .move)
            _ = advancesWithMainBlocked(for: 30) { shownX(view) }
            let before = (shownX(view), shownY(view))
            Motion.panes.set(view, frame: target, spring: .move)
            CATransaction.flush()
            return (before, (shownX(view), shownY(view)))
        }
        #expect(view.frame == target)
        #expect(keys(view, MotionGate.frameKey, path: "position.x").count == 2, "the running spring was replaced")
        #expect(keys(view, MotionGate.frameKey, path: "position.y").count == 1)
        // A replaced spring would show the old target (400) at once; the moving view covers a few
        // points between the two reads.
        let x0 = try #require(before.0), x1 = try #require(after.0)
        let y0 = try #require(before.1), y1 = try #require(after.1)
        #expect(abs(x1 - x0) < 20, "x jumped from \(x0) to \(x1)")
        #expect(abs(y1 - y0) < 20, "y jumped from \(y0) to \(y1)")
    }

    /// Movement turned off mid-move: the next change lands in one frame and takes the springs off.
    @Test(.enabled("needs an awake display and animations on") { await GUIAnimationTestSupport.animatesHere() })
    func aSnapEndsARunningMove() throws {
        let view = CountingView(frame: NSRect(x: 0, y: 20, width: 80, height: 40))
        let window = try onScreen(view)
        defer { window.orderOut(nil) }
        let target = NSRect(x: 400, y: 20, width: 80, height: 40)
        withMotion { Motion.panes.set(view, frame: target, spring: .move) }
        #expect(!keys(view, MotionGate.frameKey).isEmpty)
        let flag = Flag()
        withMotion(enabled: false) { Motion.panes.set(view, frame: target, spring: .move, completion: { flag.raised = true }) }
        #expect(flag.raised, "a snap completes in its turn")
        #expect(keys(view, MotionGate.frameKey).isEmpty, "the spring kept carrying its offset over the snap")
    }

    // MARK: One frame when nothing animates

    @Test func outOfAWindowAMoveAndAFadeLandAtOnce() {
        withMotion {
            let view = CountingView(frame: NSRect(x: 0, y: 0, width: 80, height: 40))
            view.wantsLayer = true
            let moved = Flag(), faded = Flag()
            Motion.panes.set(view, frame: NSRect(x: 50, y: 0, width: 80, height: 40), spring: .move, completion: { moved.raised = true })
            Motion.feedback.set(view, alpha: 0.5, fade: .fadeOut, completion: { faded.raised = true })
            #expect(view.frame.minX == 50 && view.alphaValue == 0.5)
            #expect(moved.raised && faded.raised, "nothing draws out of a window, so nothing waits")
            #expect(keys(view, MotionGate.frameKey).isEmpty && keys(view, MotionGate.alphaKey).isEmpty)
        }
    }

    @Test func withAnimationsOffAMoveAndAFadeLandAtOnce() {
        withMotion(enabled: false) {
            let view = CountingView(frame: NSRect(x: 0, y: 0, width: 80, height: 40))
            view.wantsLayer = true
            let moved = Flag(), faded = Flag()
            let (frames, alphas) = (view.frameWrites, view.alphaWrites)
            Motion.panes.set(view, frame: NSRect(x: 50, y: 0, width: 80, height: 40), spring: .move, completion: { moved.raised = true })
            Motion.feedback.set(view, frame: NSRect(x: 60, y: 0, width: 80, height: 40), fade: .hover)
            Motion.feedback.set(view, alpha: 0, fade: .fadeOut, completion: { faded.raised = true })
            #expect(view.frame.minX == 60 && view.alphaValue == 0)
            #expect(moved.raised && faded.raised)
            #expect(view.frameWrites - frames == 2 && view.alphaWrites - alphas == 1, "one write per change")
            #expect(keys(view, MotionGate.frameKey).isEmpty && keys(view, MotionGate.alphaKey).isEmpty)
        }
    }

    // MARK: The before result

    /// The path this replaces, `animate(_:in:_:)` with an `animator()` frame change (spring token, and
    /// the fade token "…" used), probed the same way. Recorded, not asserted: it is AppKit's behavior on
    /// the host's macOS (a SwiftUI animation on 15 and later, a timed group on 14).
    @Test(.enabled("needs an awake display and animations on") { await GUIAnimationTestSupport.animatesHere() })
    func theAnimatorPathIsRecorded() async throws {
        for spring in [true, false] {
            let view = CountingView(frame: NSRect(x: 0, y: 40, width: 80, height: 40))
            let window = try onScreen(view)
            defer { window.orderOut(nil) }
            let flag = Flag()
            let target = NSRect(x: 400, y: 40, width: 80, height: 40)
            let (inTurn, landed, advances) = withMotion { () -> (Int, Bool, Bool) in
                if spring {
                    Motion.panes.animate(.move, in: view, { view.animator().frame = target }, completion: { flag.raised = true })
                } else {
                    Motion.feedback.animate(.hover, in: view, { view.animator().frame = target }, completion: { flag.raised = true })
                }
                return (view.frameWrites, view.frame == target, advancesWithMainBlocked(for: 40) { shownX(view) })
            }
            let ended = await GUIAnimationTestSupport.settle { flag.raised }
            print("MotionGateMainWorkTests before [\(spring ? "spring .move" : "fade .hover")] "
                + "\(ProcessInfo.processInfo.operatingSystemVersionString): model landed in the turn \(landed), "
                + "frame writes in the turn \(inTurn), after it \(view.frameWrites - inTurn), "
                + "moved with main blocked \(advances), ended \(ended)")
        }
    }
}
