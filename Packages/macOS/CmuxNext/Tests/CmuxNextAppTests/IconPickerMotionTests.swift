import AppKit
@testable import CmuxNextApp
@testable import CmuxNextDesign
import Testing

/// POLISH audit, batch 4 (cx-2grmt): the icon picker appeared and left in one frame. It opens and
/// closes like every native popup (`PopupFade`). The picker opens in one frame,
/// like menus and popovers; its close still fades.
@MainActor @Suite(.serialized) struct IconPickerMotionTests {
    @Test(.enabled("needs an awake display and animations on, or every picker snaps anyway") { await GUIAnimationTestSupport.animatesHere() })
    func thePickerOpensAtOnceAndClosesWithMotion() async throws {
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 600, height: 600), styleMask: [.titled],
                              backing: .buffered, defer: false)
        defer { window.orderOut(nil) }
        window.orderFrontRegardless()
        let content = try #require(window.contentView)
        try #require(window.screen != nil)
        let picker = IconPickerService(services: nil)
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in picker.prepare { done.resume() } }
        var results: [IconPickerResult] = []
        // Synchronous inside: the override is process-wide.
        let (panel, opened) = try { () throws -> (IconPickerPanel, Bool) in
            Motion.reduceMotionOverride = false
            defer { Motion.reduceMotionOverride = nil }
            picker.pick(current: nil, target: "workspace:1", at: .init(view: content, rect: NSRect(x: 100, y: 500, width: 2, height: 2))) {
                results.append($0)
            }
            let panel = try #require(NSApp.windows.compactMap { $0 as? IconPickerPanel }.first { $0.parent === window })
            return (panel, panel.contentView?.layer?.animation(forKey: "sublayerTransform") != nil)
        }()
        #expect(!opened, "the picker animated in")
        panel.onDismiss?()
        #expect(results.count == 1)
        #expect(panel.isVisible, "closed in one frame")
        // Review: typing after a pick goes back to the window now, not into the fading picker.
        #expect(!panel.isKeyWindow, "the fading picker still takes keys")
        #expect(panel.ignoresMouseEvents, "the fading picker still takes clicks")
        try await Task.sleep(for: .milliseconds(600))
        #expect(!panel.isVisible)
        #expect(panel.parent == nil)
    }
}
