import AppKit
@testable import CmuxNextApp
import CmuxNextDesign
import Testing

/// POLISH audit, batch 4 (cx-2grmt): the icon picker appeared and left in one frame. It opens and
/// closes like every native popup (`PopupFade`).
@MainActor @Suite(.serialized) struct IconPickerMotionTests {
    static func hasDisplay() -> Bool { !NSScreen.screens.isEmpty }

    @Test(.enabled("a window with no screen applies its changes at once") { await Self.hasDisplay() })
    func thePickerOpensAndClosesWithMotion() async throws {
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
        #expect(opened, "opened in one frame")
        panel.onDismiss?()
        #expect(results.count == 1)
        #expect(panel.isVisible, "closed in one frame")
        try await Task.sleep(for: .milliseconds(600))
        #expect(!panel.isVisible)
        #expect(panel.parent == nil)
    }
}
