#if canImport(AppKit)

import AppKit
import Testing
@testable import CmuxAppKitSupportUI

/// A test double recording every window passed to the decoration seam.
@MainActor
private final class FakeWindowDecorator: WindowDecorating {
    private(set) var decoratedCount = 0
    private(set) var lastWindow: NSWindow?

    func applyWindowDecorations(to window: NSWindow) {
        decoratedCount += 1
        lastWindow = window
    }
}

@MainActor
private func makeAboutWindow() -> NSWindow {
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 360, height: 520),
        styleMask: [.titled, .closable, .miniaturizable],
        backing: .buffered,
        defer: false
    )
    window.isReleasedWhenClosed = false
    window.identifier = NSUserInterfaceItemIdentifier(AboutWindowKind.about.windowIdentifier)
    return window
}

@MainActor
@Suite struct AboutTitlebarDebugStoreTests {
    @Test func defaultsAreNonOverriding() {
        let store = AboutTitlebarDebugStore(decorator: nil)
        #expect(store.options(for: .about).overridesEnabled == false)
        #expect(store.aboutOptions == AboutTitlebarDebugOptions.defaults(for: .about))
    }

    @Test func disabledOverridesUseKindDefaults() {
        let decorator = FakeWindowDecorator()
        let store = AboutTitlebarDebugStore(decorator: decorator)
        let window = makeAboutWindow()

        var options = AboutTitlebarDebugOptions.defaults(for: .about)
        options.overridesEnabled = false
        options.windowTitle = "Ignored"
        options.resizable = true
        store.update(options, for: .about)

        store.applyCurrentOptions(to: window, for: .about)

        // Overrides disabled -> defaults: title falls back, not resizable.
        #expect(window.title == "About cmux")
        #expect(window.styleMask.contains(.resizable) == false)
        #expect(decorator.decoratedCount >= 1)
    }

    @Test func enabledOverridesApplyTitleAndStyleMask() {
        let decorator = FakeWindowDecorator()
        let store = AboutTitlebarDebugStore(decorator: decorator)
        let window = makeAboutWindow()

        var options = AboutTitlebarDebugOptions.defaults(for: .about)
        options.overridesEnabled = true
        options.windowTitle = "Custom Title"
        options.resizable = true
        options.titleVisibility = .visible
        store.update(options, for: .about)
        store.applyCurrentOptions(to: window, for: .about)

        #expect(window.title == "Custom Title")
        #expect(window.styleMask.contains(.resizable))
        #expect(window.titleVisibility == .visible)
        #expect(decorator.lastWindow === window)
    }

    @Test func emptyTitleFallsBackToKindFallback() {
        let store = AboutTitlebarDebugStore(decorator: nil)
        let window = makeAboutWindow()

        var options = AboutTitlebarDebugOptions.defaults(for: .about)
        options.overridesEnabled = true
        options.windowTitle = "   "
        store.update(options, for: .about)
        store.applyCurrentOptions(to: window, for: .about)

        #expect(window.title == AboutWindowKind.about.fallbackTitle)
    }

    @Test func showToolbarTogglesWindowToolbar() {
        let store = AboutTitlebarDebugStore(decorator: nil)
        let window = makeAboutWindow()

        var options = AboutTitlebarDebugOptions.defaults(for: .about)
        options.overridesEnabled = true
        options.showToolbar = true
        store.update(options, for: .about)
        store.applyCurrentOptions(to: window, for: .about)
        #expect(window.toolbar != nil)

        options.showToolbar = false
        store.update(options, for: .about)
        store.applyCurrentOptions(to: window, for: .about)
        #expect(window.toolbar == nil)
    }

    @Test func resetRestoresDefaults() {
        let store = AboutTitlebarDebugStore(decorator: nil)
        var options = AboutTitlebarDebugOptions.defaults(for: .about)
        options.overridesEnabled = true
        options.windowTitle = "Changed"
        store.update(options, for: .about)
        #expect(store.aboutOptions.overridesEnabled)

        store.reset(.about)
        #expect(store.aboutOptions == AboutTitlebarDebugOptions.defaults(for: .about))
    }

    @Test func copyConfigPayloadContainsCurrentValues() {
        let store = AboutTitlebarDebugStore(decorator: nil)
        var options = AboutTitlebarDebugOptions.defaults(for: .about)
        options.overridesEnabled = true
        options.windowTitle = "Snapshot Title"
        options.toolbarStyle = .unifiedCompact
        store.update(options, for: .about)

        // Assert the pure snapshot so the test never clears the process clipboard.
        let payload = store.configSnapshot()

        #expect(payload.contains("about.overridesEnabled=true"))
        #expect(payload.contains("about.title=Snapshot Title"))
        #expect(payload.contains("about.toolbarStyle=unifiedCompact"))
    }
}

#endif
