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

    @Test func resolverKeepsOverlayInsideWindowContentHierarchy() throws {
        let glass = FakeOverlayGlassEffect()
        let resolver = WindowContentOverlayTargetResolver(glassEffect: glass)
        let window = makeWindow()
        let contentView = window.contentView

        let target = try #require(resolver.installationTarget(for: window))
        let overlay = NSView(frame: target.reference.bounds)
        target.container.addSubview(overlay, positioned: .above, relativeTo: target.reference)

        #expect(target.reference === contentView)
        #expect(overlay.isDescendant(of: try #require(window.contentView)))
        #expect(target.reference.superview === target.container)
        #expect(target.container.subviews.last === overlay)
    }

    @Test func resolvingAgainPreservesContentAndOverlayIdentity() throws {
        let resolver = WindowContentOverlayTargetResolver(glassEffect: FakeOverlayGlassEffect())
        let window = makeWindow()
        let first = try #require(resolver.installationTarget(for: window))
        let overlay = NSView(frame: first.reference.bounds)
        first.container.addSubview(overlay, positioned: .above, relativeTo: first.reference)

        let second = try #require(resolver.installationTarget(for: window))

        #expect(second.container === first.container)
        #expect(second.reference === first.reference)
        #expect(overlay.superview === second.container)
    }

    @Test func wrappedContentTracksWindowResize() throws {
        let resolver = WindowContentOverlayTargetResolver(glassEffect: FakeOverlayGlassEffect())
        let window = makeWindow()
        let target = try #require(resolver.installationTarget(for: window))

        window.setContentSize(NSSize(width: 360, height: 240))
        window.contentView?.layoutSubtreeIfNeeded()

        #expect(target.reference.frame == target.container.bounds)
        #expect(target.reference.frame.size == NSSize(width: 360, height: 240))
    }

    @Test func wrappingPreservesFocusedContent() throws {
        let resolver = WindowContentOverlayTargetResolver(glassEffect: FakeOverlayGlassEffect())
        let window = makeWindow()
        let field = NSTextView(frame: NSRect(x: 0, y: 0, width: 100, height: 60))
        window.contentView?.addSubview(field)
        #expect(window.makeFirstResponder(field))

        _ = try #require(resolver.installationTarget(for: window))

        #expect(window.firstResponder === field)
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
