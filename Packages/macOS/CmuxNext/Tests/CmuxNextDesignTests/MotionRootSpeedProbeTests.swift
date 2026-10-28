import AppKit
@testable import CmuxNextDesign
import CmuxNextDesignTokens
import QuartzCore
import Testing

/// Probe (not a regression test; removed before landing): which gate paths a window's root layer
/// `speed` slows. Each path's landing time at root speed 1 and 0.25 is printed as
/// `motion-root-speed path=... base_ms=... slowed_ms=... ratio=...`.
@MainActor @Suite(.serialized) struct MotionRootSpeedProbeTests {
    final class Landed { var done = false }

    static func rig() throws -> (NSWindow, NSView) {
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
        try #require(window.screen != nil)
        return (window, view)
    }

    static func root(_ window: NSWindow) -> CALayer? { window.contentView?.superview?.layer ?? window.contentView?.layer }

    static func time(_ start: (Landed) -> Void) async -> Double? {
        let landed = Landed()
        let began = CACurrentMediaTime()
        start(landed)
        guard await GUIAnimationTestSupport.settle(within: 20, until: { landed.done }) else { return nil }
        return (CACurrentMediaTime() - began) * 1000
    }

    @Test(.enabled("needs an awake display and animations on") { await GUIAnimationTestSupport.animatesHere() })
    func rootSpeedReachesWhichPaths() async throws {
        Motion.reduceMotionOverride = false
        defer { Motion.reduceMotionOverride = nil }
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        let rootKind = { (window: NSWindow) in Self.root(window).map { String(describing: type(of: $0.delegate as Any)) } ?? "none" }
        typealias Path = (name: String, run: @MainActor (NSWindow, NSView, Landed, Bool) -> Void)
        let paths: [Path] = [
            ("appkit.spring.frame", { _, view, landed, flip in
                Motion.feedback.animate(.move, in: view, { view.animator().frame.origin.x = flip ? 100 : 160 },
                                        completion: { landed.done = true }) }),
            ("appkit.fade.alpha", { _, view, landed, flip in
                Motion.feedback.animate(.fadeIn, in: view, { view.animator().alphaValue = flip ? 0.2 : 1 },
                                        completion: { landed.done = true }) }),
            ("appkit.timed.alpha", { _, view, landed, flip in
                Motion.feedback.animateTimed(.fadeIn, in: view, { view.animator().alphaValue = flip ? 0.2 : 1 },
                                             completion: { landed.done = true }) }),
            ("appkit.timed.frame", { _, view, landed, flip in
                Motion.feedback.animateTimed(.move, in: view, { view.animator().frame.origin.x = flip ? 100 : 160 },
                                             completion: { landed.done = true }) }),
            ("appkit.timed.windowFrame", { window, view, landed, flip in
                var frame = window.frame
                frame.origin.x += flip ? -40 : 40
                Motion.feedback.animateTimed(.move, in: view, { window.animator().setFrame(frame, display: true) },
                                             completion: { landed.done = true }) }),
            ("ca.fade", { _, view, landed, flip in
                CATransaction.begin()
                CATransaction.setCompletionBlock { landed.done = true }
                Motion.feedback.set(view.layer!, "opacity", to: flip ? 0.2 : 1, fade: .fadeIn)
                CATransaction.commit() }),
            ("ca.renderSpring", { _, view, landed, flip in
                var frame = view.frame
                frame.origin.x = flip ? 100 : 160
                Motion.feedback.animate(.move, in: view, frame: frame, alpha: nil) { _ in landed.done = true } }),
        ]
        for (name, run) in paths {
            let (window, view) = try Self.rig()
            defer { window.orderOut(nil) }
            var flip = false
            func once() async -> Double? {
                flip.toggle()
                let f = flip
                return await Self.time { run(window, view, $0, f) }
            }
            _ = await once()
            let base = await once()
            let root = Self.root(window)
            let mediaNow = CACurrentMediaTime()
            let parentNow = root?.superlayer?.convertTime(mediaNow, from: nil) ?? mediaNow
            let local = root.map { $0.convertTime(mediaNow, from: nil) } ?? mediaNow
            root?.speed = 0.25
            root?.beginTime = parentNow
            root?.timeOffset = local
            let slowed = await once()
            root?.speed = 1
            root?.beginTime = 0
            root?.timeOffset = 0
            let ratio = (slowed ?? .nan) / (base ?? .nan)
            print("motion-root-speed path=\(name) root=\(rootKind(window)) base_ms=\(base.map { String(format: "%.0f", $0) } ?? "never") "
                  + "slowed_ms=\(slowed.map { String(format: "%.0f", $0) } ?? "never") ratio=\(String(format: "%.2f", ratio)) macos=\(os)")
        }
    }
}
