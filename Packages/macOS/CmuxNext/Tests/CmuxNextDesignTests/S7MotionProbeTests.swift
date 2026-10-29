import AppKit
@testable import CmuxNextDesign
import Testing

/// A diagnostic, not a test to land (branch cp/fix-tip-swift-s7-ui-probe): which part of
/// MotionGateMainWorkTests' first test makes AppKit's NSAnimationManager crash (signal 11 in
/// `___sortAnimations_block_invoke`, fleet fe0a961d). One suite per case, so each runs in its own process and a
/// crash in one does not hide the others. Every line starts with "S7MOTION".
@MainActor
enum S7MotionProbe {
    static func run(_ name: String, counting: Bool, stats: Bool) async throws {
        print("S7MOTION \(name) start")
        let window = NSWindow(contentRect: NSRect(x: 200, y: 400, width: 400, height: 200), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.orderOut(nil) }
        let content = NSView(frame: NSRect(origin: .zero, size: window.frame.size))
        content.wantsLayer = true
        window.contentView = content
        let view: NSView = counting ? MotionGateMainWorkTests.CountingView(frame: MotionGateMainWorkTests.start)
            : NSView(frame: MotionGateMainWorkTests.start)
        view.wantsLayer = true
        view.alphaValue = 0.4
        content.addSubview(view)
        window.orderFrontRegardless()
        print("S7MOTION \(name) screen=\(window.screen != nil) layer=\(type(of: view.layer!))")
        let body: @MainActor (RenderStats?) async throws -> Void = { armed in
            print("S7MOTION \(name) stats armed=\(armed != nil)")
            var landed = false
            Motion.reduceMotionOverride = false
            Motion.feedback.animate(.hover, in: view, {
                view.animator().frame = MotionGateMainWorkTests.target
                view.animator().alphaValue = 1
            }, completion: { landed = true })
            Motion.reduceMotionOverride = nil
            let end = Date().addingTimeInterval(2)
            while Date() < end { RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02)) }
            print("S7MOTION \(name) survived landed=\(landed) frame=\(view.frame)")
        }
        if stats { try await MotionGateMainWorkTests.withStats(body) } else { try await body(nil) }
        print("S7MOTION \(name) end")
    }
}

@MainActor @Suite struct S7MotionProbePlainNoStats { @Test func run() async throws { try await S7MotionProbe.run("plain-nostats", counting: false, stats: false) } }
@MainActor @Suite(.renderHooks) struct S7MotionProbePlainStats { @Test func run() async throws { try await S7MotionProbe.run("plain-stats", counting: false, stats: true) } }
@MainActor @Suite struct S7MotionProbeCountingNoStats { @Test func run() async throws { try await S7MotionProbe.run("counting-nostats", counting: true, stats: false) } }
@MainActor @Suite(.renderHooks) struct S7MotionProbeCountingStats { @Test func run() async throws { try await S7MotionProbe.run("counting-stats", counting: true, stats: true) } }
