import AppKit
@testable import CmuxNextDesign
import CmuxNextDesignTokens
import QuartzCore
import Testing

/// The main-thread writes a gate's view motion makes per frame.
///
/// A counting view (and its backing layer) records every frame and alpha write. Each case starts a
/// change, waits for the first display frame after its turn (the turn's own writes and commit are
/// not per frame), and counts what the view takes from there until it lands. The closure path
/// (`animate(.hover, in:) { view.animator()... }`, a SwiftUI-animation `NSAnimationContext` on 15 and
/// later, a timed group on 14) is the before: its counts are printed as `motion-gate-main-work` lines
/// for the commit and the plan. The layer path (`animate(_:in:frame:alpha:completion:)`) must write 0.
@MainActor @Suite(.serialized) struct MotionGateMainWorkTests {
    /// A layer whose geometry and opacity writes are counted.
    nonisolated final class CountingLayer: CALayer {
        var geometryWrites = 0
        var opacityWrites = 0
        override var position: CGPoint { didSet { geometryWrites += 1 } }
        override var bounds: CGRect { didSet { geometryWrites += 1 } }
        override var frame: CGRect { didSet { geometryWrites += 1 } }
        override var opacity: Float { didSet { opacityWrites += 1 } }
    }

    /// A layer-backed view whose frame and alpha writes are counted, with a ``CountingLayer``.
    final class CountingView: NSView {
        var frameWrites = 0
        var alphaWrites = 0
        override func makeBackingLayer() -> CALayer { CountingLayer() }
        override func setFrameOrigin(_ newOrigin: NSPoint) {
            frameWrites += 1
            super.setFrameOrigin(newOrigin)
        }
        override func setFrameSize(_ newSize: NSSize) {
            frameWrites += 1
            super.setFrameSize(newSize)
        }
        override var alphaValue: CGFloat { didSet { alphaWrites += 1 } }

        var writes: Writes {
            let layer = self.layer as? CountingLayer
            return Writes(frame: frameWrites, alpha: alphaWrites, layerGeometry: layer?.geometryWrites ?? 0,
                          layerOpacity: layer?.opacityWrites ?? 0)
        }
    }

    /// Writes counted on one view and its layer.
    struct Writes: Equatable, CustomStringConvertible {
        var frame = 0
        var alpha = 0
        var layerGeometry = 0
        var layerOpacity = 0
        /// RenderStats `frame_sets` for the view's class, in a build with its hooks.
        var frameSets: Int?

        static func - (lhs: Writes, rhs: Writes) -> Writes {
            Writes(frame: lhs.frame - rhs.frame, alpha: lhs.alpha - rhs.alpha, layerGeometry: lhs.layerGeometry - rhs.layerGeometry,
                   layerOpacity: lhs.layerOpacity - rhs.layerOpacity)
        }

        var total: Int { frame + alpha + layerGeometry + layerOpacity + (frameSets ?? 0) }

        var description: String {
            "frame_writes=\(frame) alpha_writes=\(alpha) layer_geometry=\(layerGeometry) layer_opacity=\(layerOpacity) "
                + "frame_sets=\(frameSets.map { String($0) } ?? "n/a")"
        }
    }

    /// Whether a change landed, and how.
    final class Landed {
        var done = false
        var finished: Bool?
    }

    static let start = NSRect(x: 100, y: 80, width: 24, height: 24)
    static let target = NSRect(x: 140, y: 80, width: 24, height: 24)

    /// An ordered-in borderless window with a layer-backed content view holding one counting view at ``start``.
    static func rig() throws -> (NSWindow, CountingView) {
        let window = NSWindow(contentRect: NSRect(x: 200, y: 400, width: 400, height: 200), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let content = NSView(frame: NSRect(origin: .zero, size: window.frame.size))
        content.wantsLayer = true
        window.contentView = content
        let view = CountingView(frame: start)
        view.wantsLayer = true
        view.alphaValue = 0.4
        content.addSubview(view)
        window.orderFrontRegardless()
        try #require(window.screen != nil, "the window is on no screen: every change applies at once")
        try #require(view.layer is CountingLayer)
        return (window, view)
    }

    /// Runs `body` with RenderStats armed and counting (nil in a build without its hooks), then disarms it.
    static func withStats(_ body: @MainActor (RenderStats?) async throws -> Void) async throws {
        let stats = RenderStats()
        var counting: RenderStats?
        if stats.arm() {
            if await stats.ready() { counting = stats } else { stats.disarm() }
        }
        do {
            try await body(counting)
        } catch {
            await release(counting)
            throw error
        }
        await release(counting)
    }

    static func release(_ stats: RenderStats?) async {
        guard let stats else { return }
        stats.disarm()
        _ = await stats.ready()
    }

    /// Starts `change` (Reduce Motion off), which sets `landed.done` when it lands, and returns the writes
    /// `view` took from the first display frame after the change's turn until then, or nil when it never landed.
    static func perFrameWrites(of view: CountingView, stats: RenderStats?, landed: Landed,
                               _ change: () -> Void) async throws -> Writes? {
        Motion.reduceMotionOverride = false
        change()
        Motion.reduceMotionOverride = nil
        let screen = try #require(view.window?.screen)
        try #require(await GUIAnimationTestSupport.nextFrame(on: screen), "no display frame after the change")
        try #require(!landed.done, "the change landed before its first frame: nothing to count")
        let before = view.writes
        stats?.reset()
        guard await GUIAnimationTestSupport.settle(until: { landed.done }) else { return nil }
        var writes = view.writes - before
        writes.frameSets = stats.map { stats in
            stats.owners().first { $0.key == RenderStats.classKey(CountingView.self) }?.totals[.frameSets] ?? 0
        }
        return writes
    }

    // MARK: Before: the closure path

    /// The before (not asserted): what AppKit writes per frame for an `animator()` frame and alpha change
    /// in the gate's fade and spring groups. The fleet run's lines go in the commit and the plan.
    @Test(.enabled("needs an awake display and animations on") { await GUIAnimationTestSupport.animatesHere() })
    func theAnimatorPathsWritesPerFrameAreRecorded() async throws {
        let (window, view) = try Self.rig()
        defer { window.orderOut(nil) }
        try #require(Motion.feedback.isEnabled)
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        try await Self.withStats { stats in
            let fadeLanded = Landed()
            let fade = try await Self.perFrameWrites(of: view, stats: stats, landed: fadeLanded) {
                Motion.feedback.animate(.hover, in: view, {
                    view.animator().frame = Self.target
                    view.animator().alphaValue = 1
                }, completion: { fadeLanded.done = true })
            }
            let fadeWrites = try #require(fade, "the fade never landed")
            print("motion-gate-main-work path=animator token=hover macos=\(os) \(fadeWrites)")

            let springLanded = Landed()
            let spring = try await Self.perFrameWrites(of: view, stats: stats, landed: springLanded) {
                Motion.feedback.animate(.move, in: view, {
                    view.animator().frame = Self.start
                    view.animator().alphaValue = 0.4
                }, completion: { springLanded.done = true })
            }
            let springWrites = try #require(spring, "the spring never landed")
            print("motion-gate-main-work path=animator token=move macos=\(os) \(springWrites)")
        }
    }

    // MARK: After: the layer path

    @Test(.enabled("needs an awake display and animations on") { await GUIAnimationTestSupport.animatesHere() })
    func aFadeTokenMovesTheFrameAndAlphaWithNoWritePerFrame() async throws {
        let (window, view) = try Self.rig()
        defer { window.orderOut(nil) }
        try #require(Motion.feedback.isEnabled)
        try await Self.withStats { stats in
            let landed = Landed()
            let writes = try await Self.perFrameWrites(of: view, stats: stats, landed: landed) {
                Motion.feedback.animate(.hover, in: view, frame: Self.target, alpha: 1) { finished in
                    landed.finished = finished
                    landed.done = true
                }
                #expect(view.frame == Self.target && view.alphaValue == 1, "the view holds its targets in the change's turn")
                let keys = view.layer?.animationKeys() ?? []
                #expect(keys.contains { $0.hasSuffix(".position") } && keys.contains { $0.hasSuffix(".opacity") },
                        "the layer shows the move and the fade: \(keys)")
            }
            let measured = try #require(writes, "the move never landed")
            print("motion-gate-main-work path=layer token=hover \(measured)")
            #expect(measured.total == 0, "main-thread writes per frame: \(measured)")
            #expect(landed.finished == true)
        }
    }

    @Test(.enabled("needs an awake display and animations on") { await GUIAnimationTestSupport.animatesHere() })
    func aSpringTokenMovesTheFrameAndAlphaWithNoWritePerFrame() async throws {
        let (window, view) = try Self.rig()
        defer { window.orderOut(nil) }
        try #require(Motion.feedback.isEnabled)
        try await Self.withStats { stats in
            let landed = Landed()
            let writes = try await Self.perFrameWrites(of: view, stats: stats, landed: landed) {
                Motion.feedback.animate(.move, in: view, frame: Self.target, alpha: 1) { finished in
                    landed.finished = finished
                    landed.done = true
                }
                #expect(view.frame == Self.target && view.alphaValue == 1, "the view holds its targets in the change's turn")
                #expect(view.layer?.animationKeys()?.contains { $0.hasSuffix(".position") } == true, "the layer shows the move")
            }
            let measured = try #require(writes, "the spring never landed")
            print("motion-gate-main-work path=layer token=move \(measured)")
            #expect(measured.total == 0, "main-thread writes per frame: \(measured)")
            #expect(landed.finished == true)
        }
    }

    /// A retarget mid-move lands once: the first call ends not finished at the retarget, the second
    /// finished, and the view rests on the second target with no write per frame.
    @Test(.enabled("needs an awake display and animations on") { await GUIAnimationTestSupport.animatesHere() })
    func aRetargetMidMoveLandsOnTheNewTarget() async throws {
        let (window, view) = try Self.rig()
        defer { window.orderOut(nil) }
        try #require(Motion.feedback.isEnabled)
        let first = Landed(), second = Landed()
        let writes = try await Self.perFrameWrites(of: view, stats: nil, landed: second) {
            Motion.feedback.animate(.move, in: view, frame: Self.target) { finished in
                first.finished = finished
                first.done = true
            }
            Motion.feedback.animate(.move, in: view, frame: Self.start) { finished in
                second.finished = finished
                second.done = true
            }
        }
        let measured = try #require(writes, "the retarget never landed")
        #expect(first.done && first.finished == false, "the first call ends not finished when the second takes over")
        #expect(second.finished == true)
        #expect(view.frame == Self.start)
        #expect(measured.total == 0, "main-thread writes per frame: \(measured)")
    }

    // MARK: No display needed

    /// A view with no layer has nothing to show the move on: it takes its targets now and lands now.
    @Test func aViewWithNoLayerTakesItsTargetsAndLandsAtOnce() {
        let view = NSView(frame: Self.start)
        #expect(view.layer == nil)
        let landed = Landed()
        Motion.feedback.animate(.move, in: view, frame: Self.target, alpha: 0.5) { finished in
            landed.finished = finished
            landed.done = true
        }
        #expect(view.frame == Self.target && view.alphaValue == 0.5)
        #expect(landed.done && landed.finished == true)
    }

    /// Under Reduce Motion a fade token's frame change shows in one frame (motion.md rule 7) and only
    /// the alpha fades.
    @Test func underReduceMotionOnlyTheAlphaFades() throws {
        let parent = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        parent.wantsLayer = true
        let view = NSView(frame: Self.start)
        view.wantsLayer = true
        view.alphaValue = 0.4
        parent.addSubview(view)
        try #require(view.layer?.superlayer === parent.layer)
        Motion.reduceMotionOverride = true
        defer { Motion.reduceMotionOverride = nil }
        let fades = Motion.feedback.duration(MotionFade.fadeIn) > 0
        Motion.feedback.animate(.fadeIn, in: view, frame: Self.target, alpha: 1)
        let keys = view.layer?.animationKeys() ?? []
        #expect(view.frame == Self.target && view.alphaValue == 1)
        #expect(!keys.contains { $0.hasSuffix(".position") }, "the frame moved under Reduce Motion: \(keys)")
        #expect(keys.contains { $0.hasSuffix(".opacity") } == fades, "\(keys)")
    }

    /// With movement off (Reduce Motion) a spring token's alpha change still crossfades on the layer, so
    /// motion is in flight for the crossfade's length (``MotionActivity``, which ``MotionLateCommits`` judges
    /// commits during), not for the spring's 0 seconds.
    @Test func underReduceMotionASpringTokensCrossfadeIsMotionInFlight() throws {
        let parent = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        parent.wantsLayer = true
        let view = NSView(frame: Self.start)
        view.wantsLayer = true
        view.alphaValue = 0.4
        parent.addSubview(view)
        try #require(view.layer?.superlayer === parent.layer)
        Motion.reduceMotionOverride = true
        defer { Motion.reduceMotionOverride = nil }
        try #require(!Motion.feedback.animatesMovement && Motion.feedback.duration(MotionSpring.move) == 0)
        let crossfade = Motion.feedback.duration(MotionFade.crossfade)
        try #require(crossfade > 0, "Reduce Motion keeps a crossfade")
        MotionActivity.reset()
        let start = CACurrentMediaTime()
        Motion.feedback.animate(.move, in: view, frame: nil, alpha: 1)
        let keys = view.layer?.animationKeys() ?? []
        #expect(keys.contains { $0.hasSuffix(".opacity") }, "the alpha crossfades: \(keys)")
        #expect(MotionActivity.isAnimating, "the crossfade is motion in flight")
        #expect(MotionActivity.end >= start + crossfade, "motion ends at the crossfade's end")
    }
}
