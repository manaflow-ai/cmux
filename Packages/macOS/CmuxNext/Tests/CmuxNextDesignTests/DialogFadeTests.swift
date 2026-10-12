import AppKit
@testable import CmuxNextDesign
import Testing

/// POLISH (no flash): a window dialog and its scrim appeared in one frame, so the whole window
/// darkened at once. Both fade in with the fade-in token, which Reduce Motion keeps.
@MainActor @Suite(.serialized) struct DialogFadeTests {
    @Test func aDialogAndItsScrimFadeInInsteadOfAppearingInOneFrame() throws {
        // Synchronous from here to the reset: the override is process-wide.
        Motion.reduceMotionOverride = true
        defer { Motion.reduceMotionOverride = nil }
        let window = NSWindow(contentRect: NSRect(x: 200, y: 400, width: 400, height: 300), styleMask: [.titled],
                              backing: .buffered, defer: false)
        defer { window.orderOut(nil) }
        let host = WindowOverlayHost.host(for: window)
        let dialog = NSView(frame: NSRect(x: 0, y: 0, width: 160, height: 90))
        let handle = host.present(dialog, options: OverlayOptions(kind: .dialog, isModal: true, dimsContent: true,
                                                                  passesThroughClicks: false))
        defer { handle.dismiss() }
        let container = host.panel.container(for: handle.options.effectiveLayer)
        let scrim = try #require(container.subviews.first { $0 is OverlayScrimView })
        for (name, view) in [("scrim", scrim), ("dialog", dialog)] {
            let fade = view.layer?.animation(forKey: "opacity") as? CABasicAnimation
            #expect((fade?.fromValue as? NSNumber)?.floatValue == 0, "\(name) appeared in one frame")
            #expect(view.layer?.opacity == 1, "\(name)")
        }
    }
}
