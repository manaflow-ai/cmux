import AppKit
@testable import CmuxNextDesign
import CmuxNextWakeups
import QuartzCore
import Testing

/// A window whose visibility a test sets: its ``WindowVisibilitySource`` reads ``state`` instead of
/// AppKit, so a hidden, occluded or visible window needs no screen.
@MainActor final class LoopTestWindow {
    var state: Visibility
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.borderless],
                          backing: .buffered, defer: true)
    private(set) var source: WindowVisibilitySource!

    init(_ state: Visibility = .visible) {
        self.state = state
        window.isReleasedWhenClosed = false
        source = WindowVisibilitySource.of(window, name: "loopTestWindow") { [unowned self] _ in self.state }
    }

    /// Sets the window's state, as an occlusion or miniaturize notice would.
    func set(_ state: Visibility) {
        self.state = state
        source.refresh()
    }
}

/// Infinite loops run only while their view is visible (p03-rendering-070): a hidden or occluded
/// window, a hidden view or a view in no window keeps no loop in the render server, and a loop that
/// shows again begins at the shared clock's phase.
@MainActor @Suite(.serialized) struct LoopVisibilityTests {
    @Test func aHiddenSpinnerRunsNoLoopAndAShownOneRunsOne() throws {
        Motion.reduceMotionOverride = false
        defer { Motion.reduceMotionOverride = nil }
        let host = LoopTestWindow()
        let loops = LoopVisibility("test.spinner")
        let spinner = CALayer()
        loops.node.set(.hidden)
        loops.place(in: host.window)
        loops.attach(spinner, key: "spin") { Motion.indicators.spinAnimation() }
        #expect(spinner.animation(forKey: "spin") == nil, "a hidden spinner runs its loop")
        #expect(loops.runningCount == 0)

        loops.node.set(.visible)
        #expect(spinner.animation(forKey: "spin") != nil, "a shown spinner does not turn")
        #expect(loops.runningCount == 1)

        host.set(.occluded)
        #expect(loops.runningCount == 0, "an occluded window keeps its spinner turning")
        host.set(.visible)
        #expect(loops.runningCount == 1, "the spinner does not come back when the window shows")
        host.set(.hidden)
        #expect(loops.runningCount == 0, "a miniaturized window keeps its spinner turning")
        host.set(.visible)

        loops.place(in: nil)
        #expect(loops.runningCount == 0, "a spinner out of its window keeps turning")
        loops.place(in: host.window)
        #expect(loops.runningCount == 1)
    }

    /// A window fully under an opaque cmux window of the same size: AppKit still says visible, its
    /// occlusion family says occluded (p03-rendering-097, crbug.com/883031), and its loops come off
    /// until the family clears.
    @Test func aSameSizeCoveredWindowRunsNoLoop() {
        Motion.reduceMotionOverride = false
        defer { Motion.reduceMotionOverride = nil }
        let host = LoopTestWindow(.visible)
        let loops = LoopVisibility("test.covered")
        loops.place(in: host.window)
        let a = CALayer(), b = CALayer()
        loops.attach(a, key: "spin") { Motion.indicators.spinAnimation() }
        loops.attach(b, key: "spin") { Motion.indicators.spinAnimation() }
        #expect(loops.runningCount == 2)

        let family = WindowOcclusionFamily.of(host.window)
        family.set(occluded: true)
        #expect(host.state == .visible, "the fake AppKit read still says visible")
        #expect(loops.runningCount == 0, "a window a same-size cmux window covers keeps its loops")
        family.set(occluded: false)
        #expect(loops.runningCount == 2, "the loops do not come back when the cover goes")
    }

    /// A loop that starts, or starts again after its window was occluded, begins at the phase the
    /// shared clock gives it, so it sits where one running all along would; its own offset stays.
    @Test func aLoopBeginsAtTheSharedClocksPhase() throws {
        let clock = SpinnerClock(mediaTime: { 100 }, unixTime: { 1_000.25 })
        let host = LoopTestWindow()
        let loops = LoopVisibility("test.phase", clock: clock)
        loops.place(in: host.window)
        let layer = CALayer()
        func turn() -> CAAnimation {
            let animation = CABasicAnimation(keyPath: "opacity")
            animation.duration = 1
            animation.timeOffset = 0.1
            animation.repeatCount = .infinity
            return animation
        }
        loops.attach(layer, key: "loop", make: turn)
        let first = try #require(layer.animation(forKey: "loop"))
        #expect(first.beginTime == 99.75, "a quarter turn done at media time 100: \(first.beginTime)")
        #expect(first.timeOffset == 0.1, "the loop's own offset was lost")

        host.set(.occluded)
        host.set(.visible)
        let again = try #require(layer.animation(forKey: "loop"))
        #expect(again.beginTime == 99.75)

        let reversing = CALayer()
        loops.attach(reversing, key: "breath") {
            let breath = CABasicAnimation(keyPath: "opacity")
            breath.duration = 2
            breath.autoreverses = true
            breath.repeatCount = .infinity
            return breath
        }
        // An autoreversing loop's cycle is twice its duration: 1000.25 mod 4 = 0.25.
        #expect(reversing.animation(forKey: "breath")?.beginTime == 99.75)
    }

    /// Loops off (Reduce Motion): the make returns nil and the layer keeps no loop, visible or not.
    @Test func loopsOffAttachNothing() {
        Motion.reduceMotionOverride = true
        defer { Motion.reduceMotionOverride = nil }
        let host = LoopTestWindow()
        let loops = LoopVisibility("test.reduced")
        loops.place(in: host.window)
        let spinner = CALayer()
        loops.attach(spinner, key: "spin") { Motion.indicators.spinAnimation() }
        #expect(loops.isAttached(spinner, key: "spin"))
        #expect(loops.runningCount == 0, "a spinner turns under Reduce Motion")
    }

    /// Detaching takes the loop off for good, and a view with no loop keeps no subscriber on its node.
    @Test func detachTakesTheLoopOffAndDropsTheSubscription() {
        Motion.reduceMotionOverride = false
        defer { Motion.reduceMotionOverride = nil }
        let host = LoopTestWindow()
        let loops = LoopVisibility("test.detach")
        loops.place(in: host.window)
        #expect(loops.node.subscriberCounts.flips == 0)
        let a = CALayer(), b = CALayer()
        loops.attach(a, key: "spin") { Motion.indicators.spinAnimation() }
        loops.attach(b, key: "spin") { Motion.indicators.spinAnimation() }
        #expect(loops.runningCount == 2)
        #expect(loops.node.subscriberCounts.flips == 1, "one subscription per LoopVisibility, not per loop")

        loops.detach(a, key: "spin")
        #expect(a.animation(forKey: "spin") == nil)
        host.set(.occluded)
        host.set(.visible)
        #expect(a.animation(forKey: "spin") == nil, "a detached loop came back")
        #expect(b.animation(forKey: "spin") != nil)

        loops.detachAll()
        #expect(b.animation(forKey: "spin") == nil)
        #expect(loops.node.subscriberCounts.flips == 0, "an idle view still follows its node")
    }

    /// The night sky's 93 loops (90 twinkles, 3 rising Zs) run only while its window shows.
    @Test func theNightSkyRunsNoLoopWhileHiddenOrOccluded() throws {
        let host = LoopTestWindow()
        let sky = NightSkyView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        host.window.contentView = sky
        sky.layout()
        func running() -> Int {
            (sky.layer?.sublayers ?? []).filter { layer in
                layer.animation(forKey: NightSkyView.twinkleKey) != nil || layer.animation(forKey: NightSkyView.riseKey) != nil
            }.count
        }
        #expect(running() == 93, "90 stars and 3 Zs")
        host.set(.occluded)
        #expect(running() == 0, "an occluded sky twinkles")
        host.set(.visible)
        #expect(running() == 93)
        sky.isHidden = true
        #expect(running() == 0, "a hidden sky twinkles")
        sky.isHidden = false
        #expect(running() == 93)
        host.window.contentView = NSView()
        #expect(running() == 0, "a sky out of its window twinkles")
    }
}
