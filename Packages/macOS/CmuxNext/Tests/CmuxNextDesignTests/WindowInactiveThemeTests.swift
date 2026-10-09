import AppKit
import Testing
@testable import CmuxNextDesign

/// Dogfood 2026-10-08 (C3): an inactive cmux-next window lost its theme and went
/// plain grey. Liquid Glass drops its `tintColor` while its window is not key
/// and draws the system's grey; cmux classic lays the theme tint back over the
/// glass then (`WindowGlassEffect.GlassBackgroundView`). An inactive window
/// keeps the theme: the same tint, the same material and art, with at most
/// classic's mild wash.
@MainActor
@Suite(.serialized) struct WindowInactiveThemeTests {
    init() { _ = NSApplication.shared }

    static let dark = NSColor(srgbRed: 0.12, green: 0.10, blue: 0.20, alpha: 1)
    static let light = NSColor(srgbRed: 0.96, green: 0.94, blue: 0.90, alpha: 1)

    /// A backdrop in an off-screen window, so key changes reach it.
    static func hosted(_ backdrop: WindowBackdrop, tint: NSColor) -> (NSWindow, WindowMaterialView) {
        let window = NSWindow(contentRect: NSRect(x: -30_000, y: -30_000, width: 400, height: 300), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let view = WindowMaterialView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        window.contentView?.addSubview(view)
        view.apply(backdrop, tint: tint)
        return (window, view)
    }

    static func resignKey(_ window: NSWindow) {
        // global-notice-allow: on main, an AppKit notice AppKit itself posts here; the observer under test takes no center yet
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
    }

    static func becomeKey(_ window: NSWindow) {
        // global-notice-allow: on main, an AppKit notice AppKit itself posts here; the observer under test takes no center yet
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
    }

    /// Glass goes grey while the window is not key: the theme tint comes back
    /// over it, stronger over a dark theme and lighter over a light one
    /// (classic's 0.85 and 0.35), and leaves again when the window is key.
    @Test(arguments: [(false, 0.85), (true, 0.35)])
    func anInactiveGlassWindowKeepsTheThemeTint(lightTheme: Bool, alpha: Double) throws {
        let tint = lightTheme ? Self.light : Self.dark
        let (window, view) = Self.hosted(WindowBackdrop(backgroundOpacity: 0.8, backgroundBlur: -1), tint: tint)
        defer { window.close() }
        #expect(view.inactiveTintAlpha == 0, "a window that was never key shows the glass alone")
        Self.becomeKey(window)
        #expect(view.inactiveTintAlpha == 0, "a key window shows the glass as it is")
        Self.resignKey(window)
        #expect(abs(view.inactiveTintAlpha - alpha) < 0.001)
        let glassTint = try #require(view.tintColor)
        #expect(view.inactiveTintColor == glassTint, "the overlay is the theme tint the glass was given")
        Self.becomeKey(window)
        #expect(view.inactiveTintAlpha == 0)
    }

    /// What the theme gives the window is the same active and inactive: the
    /// material, the tint and the art. Only glass gets the overlay; the other
    /// materials draw their own tint and never go grey.
    @Test(arguments: [(1.0, 0), (0.8, 0), (0.8, 20), (0.8, -1), (0.6, -2)])
    func theThemeIsTheSameActiveAndInactive(opacity: Double, blur: Int) {
        let backdrop = WindowBackdrop(backgroundOpacity: opacity, backgroundBlur: blur)
        let (window, view) = Self.hosted(backdrop, tint: Self.dark)
        defer { window.close() }
        Self.becomeKey(window)
        let active = (view.material, view.tintColor, view.isHidden, view.alphaValue)
        Self.resignKey(window)
        #expect(view.material == active.0)
        #expect(view.tintColor == active.1)
        #expect(view.isHidden == active.2 && view.alphaValue == active.3, "no fade, no layout change")
        if case .glass = backdrop.material {
            #expect(view.inactiveTintAlpha > 0)
        } else {
            #expect(view.inactiveTintAlpha == 0, "only glass drops its tint when inactive")
        }
    }
}
