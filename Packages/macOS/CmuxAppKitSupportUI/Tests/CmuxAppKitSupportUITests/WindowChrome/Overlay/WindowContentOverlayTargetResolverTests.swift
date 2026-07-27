import AppKit
import Testing

@testable import CmuxAppKitSupportUI

@MainActor
@Suite struct WindowContentOverlayTargetResolverTests {
    @Test func resolverPrefersInjectedGlassForegroundTarget() {
        let glass = FakeOverlayGlassEffect()
        let resolver = WindowContentOverlayTargetResolver(glassEffect: glass)
        let window = makeWindow()
        let container = NSView()
        let reference = NSView()
        glass.portalInstallationTargetResult = WindowContentOverlayInstallationTarget(
            container: container,
            reference: reference
        )

        let target = resolver.installationTarget(for: window)

        #expect(target?.container === container)
        #expect(target?.reference === reference)
    }

    @Test func resolverFallsBackToThemeFrameAndContentView() {
        let glass = FakeOverlayGlassEffect()
        let resolver = WindowContentOverlayTargetResolver(glassEffect: glass)
        let window = makeWindow()
        let contentView = window.contentView

        let target = resolver.installationTarget(for: window)

        #expect(target?.container === contentView?.superview)
        #expect(target?.reference === contentView)
    }

    private func makeWindow() -> NSWindow {
        let contentView = NSView(frame: NSRect(x: 0, y: 0, width: 120, height: 80))
        let window = NSWindow(
            contentRect: contentView.bounds,
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.contentView = contentView
        return window
    }
}

@MainActor
private final class FakeOverlayGlassEffect: WindowGlassEffectManaging {
    var backgroundViewIdentifier = NSUserInterfaceItemIdentifier("fake.overlay.background")
    var isAvailable = true
    var portalInstallationTargetResult: WindowContentOverlayInstallationTarget?

    func apply(
        to window: NSWindow,
        tintColor: NSColor?,
        style: WindowGlassEffectStyle?
    ) -> Bool {
        false
    }

    func updateTint(to window: NSWindow, color: NSColor?) {}

    func remove(from window: NSWindow) -> Bool {
        false
    }

    func foregroundContainer(for window: NSWindow) -> NSView? {
        nil
    }

    func originalContentView(for window: NSWindow) -> NSView? {
        nil
    }

    func portalInstallationTarget(for window: NSWindow) -> WindowContentOverlayInstallationTarget? {
        portalInstallationTargetResult
    }
}
