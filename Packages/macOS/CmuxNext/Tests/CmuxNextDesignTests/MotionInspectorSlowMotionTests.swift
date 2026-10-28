import AppKit
@testable import CmuxNextDesign
import CmuxNextDesignTokens
import QuartzCore
import Testing

/// Slow motion on screen (GUI host): each gate path's animation lands about `slowdown` times later under the
/// Motion Inspector's time scale than at 1x, is listed with its category, call site and curve, and lands at
/// its 1x time again once the inspection stops. In the same serialized suite as ``MotionInspectorTests``: both
/// drive the process's one set of inspector statics.
extension MotionInspectorTests {
    final class Landed {
        var done = false
    }

    /// A window on screen with one layer-backed view, and an inspector over it on the real media clock.
    static func slowMotionRig() throws -> (NSWindow, NSView, MotionInspector) {
        let window = NSWindow(contentRect: NSRect(x: 200, y: 400, width: 400, height: 200), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let content = NSView(frame: NSRect(origin: .zero, size: window.contentLayoutRect.size))
        content.wantsLayer = true
        window.contentView = content
        let view = NSView(frame: NSRect(x: 100, y: 80, width: 24, height: 24))
        view.wantsLayer = true
        view.alphaValue = 0.2
        content.addSubview(view)
        window.orderFrontRegardless()
        try #require(window.screen != nil, "the window is on no screen: every change applies at once")
        Motion.reduceMotionOverride = false
        let inspector = MotionInspector(windows: { [window] }, design: .shared)
        return (window, view, inspector)
    }

    /// Milliseconds from `start` to its landing, or nil when it never landed.
    static func landing(_ start: (Landed) -> Void) async -> Double? {
        let landed = Landed()
        let began = CACurrentMediaTime()
        start(landed)
        guard await GUIAnimationTestSupport.settle(within: 20, until: { landed.done }) else { return nil }
        return (CACurrentMediaTime() - began) * 1000
    }

    /// One gate path: what it starts (flipping between two targets each call) and the record kind it lists.
    struct GatePath: CustomStringConvertible, Sendable {
        var name: String
        var kindPrefix: String
        var run: @MainActor @Sendable (NSView, Landed, Bool) -> Void
        var description: String { name }
    }

    nonisolated static let gatePaths: [GatePath] = [
        GatePath(name: "layer fade (Motion.set fade:)", kindPrefix: "timed.opacity") { view, landed, flip in
            CATransaction.begin()
            CATransaction.setCompletionBlock { landed.done = true }
            Motion.feedback.set(view.layer!, "opacity", to: Float(flip ? 0.2 : 1), fade: .fadeIn)
            CATransaction.commit()
        },
        GatePath(name: "render-server spring (animate(_:in:frame:))", kindPrefix: "render.position") { view, landed, flip in
            var frame = view.frame
            frame.origin.x = flip ? 100 : 160
            Motion.feedback.animate(.move, in: view, frame: frame) { _ in landed.done = true }
        },
        GatePath(name: "AppKit fade (animate(.fadeIn) { animator() })", kindPrefix: "appkit.fadeIn") { view, landed, flip in
            Motion.feedback.animate(.fadeIn, in: view, { view.animator().alphaValue = flip ? 0.2 : 1 }, completion: { landed.done = true })
        },
        GatePath(name: "AppKit spring (animate(.move) { animator() })", kindPrefix: "appkit.move") { view, landed, flip in
            Motion.feedback.animate(.move, in: view, { view.animator().frame.origin.x = flip ? 100 : 160 }, completion: { landed.done = true })
        },
        GatePath(name: "AppKit timed (animateTimed(.fadeIn))", kindPrefix: "timed.fadeIn") { view, landed, flip in
            Motion.feedback.animateTimed(.fadeIn, in: view, { view.animator().alphaValue = flip ? 0.2 : 1 }, completion: { landed.done = true })
        },
    ]

    @Test(.enabled("needs an awake display and animations on") { await GUIAnimationTestSupport.animatesHere() },
          arguments: gatePaths)
    func slowMotionLengthensEveryGatePathAndStopRestoresIt(_ path: GatePath) async throws {
        let (window, view, inspector) = try Self.slowMotionRig()
        defer {
            Self.release(inspector)
            window.orderOut(nil)
        }
        var flip = false
        func once() async -> Double? {
            flip.toggle()
            let target = flip
            return await Self.landing { path.run(view, $0, target) }
        }
        _ = await once()  // warm: the first change of a fresh window pays its first commit
        let base = try #require(await once(), "\(path) never landed at 1x")
        inspector.setTimeScale(.x5)
        let slowed = try #require(await once(), "\(path) never landed at 5x")
        // By this file's call site: another suite's animation in the same process cannot be taken for this one.
        let record = try #require(inspector.records.last { $0.kind.hasPrefix(path.kindPrefix) && Self.isOurs($0) },
                                  "\(path) is not in the list: \(inspector.records.map(\.kind))")
        #expect(record.category == .feedback)
        #expect(record.site?.hasPrefix("CmuxNextDesignTests/MotionInspectorSlowMotionTests.swift:") == true, "owner \(record.owner)")
        inspector.stop()
        let restored = try #require(await once(), "\(path) never landed after stop")
        print("motion-inspector-slow path=\"\(path)\" base_ms=\(Int(base)) x5_ms=\(Int(slowed)) restored_ms=\(Int(restored))")
        // About 5x: not slowed twice (a layer speed times a start scale would be 25x).
        #expect(slowed > base * 3 && slowed < base * 8 + 100, "at 5x \(path) took \(Int(slowed)) ms, at 1x \(Int(base)) ms")
        #expect(restored < base * 2 + 50, "after stop \(path) took \(Int(restored)) ms, at 1x \(Int(base)) ms")
    }

    /// Paused, a layer fade holds its value on screen; a step forward moves it one display frame of the fade.
    @Test(.enabled("needs an awake display and animations on") { await GUIAnimationTestSupport.animatesHere() })
    func pausedALayerFadeHoldsAndAStepMovesItOneFrame() async throws {
        let (window, view, inspector) = try Self.slowMotionRig()
        defer {
            Self.release(inspector)
            window.orderOut(nil)
        }
        let layer = try #require(view.layer)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.opacity = 0
        CATransaction.commit()
        inspector.setTimeScale(.paused)
        Motion.feedback.set(layer, "opacity", to: Float(1), fade: .fadeIn)
        let screen = try #require(window.screen)
        try #require(await GUIAnimationTestSupport.nextFrame(on: screen))
        try #require(await GUIAnimationTestSupport.nextFrame(on: screen))
        let held = layer.presentation()?.opacity ?? -1
        #expect(held < 0.05, "paused, the fade has not moved: \(held)")
        for _ in 0..<3 { inspector.step(frames: 1) }
        try #require(await GUIAnimationTestSupport.nextFrame(on: screen))
        let stepped = layer.presentation()?.opacity ?? -1
        #expect(stepped > held + 0.05 && stepped < 1, "three steps moved the fade part way: \(held) -> \(stepped)")
        let record = try #require(inspector.records.last { Self.isOurs($0) && $0.property == "opacity" })
        #expect(record.isRunning && record.frames == 3, "three stepped frames counted: \(record.frames)")
    }

    /// The inspector's own cost while it lists running animations is small: a 4 ms frame budget is far.
    @Test(.enabled("needs an awake display and animations on") { await GUIAnimationTestSupport.animatesHere() })
    func theInspectorsOwnCostPerFrameIsMeasured() async throws {
        let (window, view, inspector) = try Self.slowMotionRig()
        defer {
            Self.release(inspector)
            window.orderOut(nil)
        }
        inspector.setTimeScale(.x2)
        let landed = Landed()
        Motion.feedback.animate(.move, in: view, frame: NSRect(x: 160, y: 80, width: 24, height: 24)) { _ in landed.done = true }
        #expect(await GUIAnimationTestSupport.settle(within: 20, until: { landed.done }))
        let overhead = inspector.overhead
        print("motion-inspector-overhead frames=\(overhead.frameMs.count) p50_ms=\(overhead.framePercentile(0.5)) "
              + "p95_ms=\(overhead.framePercentile(0.95)) max_ms=\(overhead.framePercentile(1)) start_mean_ms=\(overhead.noteMeanMs)")
        // Measured and reported, not gated: a shared fleet host's timing is not a pass or fail.
        #expect(overhead.frameMs.count > 0, "the inspector counted the frames of the running animation")
    }

    /// A gate animation is not a finding; an animation no gate made, on a view's layer, is one.
    @Test(.enabled("needs an awake display and animations on") { await GUIAnimationTestSupport.animatesHere() })
    func theScanListsOnlyAnimationsNoGateMade() async throws {
        let (window, view, inspector) = try Self.slowMotionRig()
        defer {
            Self.release(inspector)
            window.orderOut(nil)
        }
        inspector.start()
        let layer = try #require(view.layer)
        Motion.feedback.set(layer, "opacity", to: Float(1), fade: .fadeIn)
        let raw = CALayer()
        layer.addSublayer(raw)
        // motion: allow the test's deliberate ungated animation, the scan's finding
        let ungated = CABasicAnimation(keyPath: "position.x")
        ungated.fromValue = 0
        ungated.toValue = 40
        ungated.duration = 30
        raw.add(ungated, forKey: "test.ungated")
        let findings = inspector.scan()
        #expect(findings.contains { $0.key == "test.ungated" && $0.property == "position.x" }, "the ungated move is a finding: \(findings)")
        #expect(!findings.contains { $0.property == "opacity" && $0.ownerType == String(describing: type(of: view)) },
                "the gate's fade is not a finding: \(findings)")
        raw.removeAllAnimations()
    }

    /// A record this file's code started.
    static func isOurs(_ record: MotionInspectorRecord) -> Bool {
        record.site?.hasPrefix("CmuxNextDesignTests/MotionInspectorSlowMotionTests.swift:") == true
    }
}
