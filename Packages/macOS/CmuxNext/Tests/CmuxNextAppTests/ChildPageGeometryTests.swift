import AppKit
@testable import CmuxNextApp
import Testing

/// Chromium page windows stay on their panes whatever moves the window
/// (plans/cmux-next/browser.md, child-window rules).
@MainActor
struct ChildPageGeometryTests {
    static func window(_ rect: NSRect, borderless: Bool = false) -> NSWindow {
        let window = NSWindow(contentRect: rect, styleMask: borderless ? [.borderless] : [.titled, .resizable],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        return window
    }

    /// Rectangle (and every AX window manager) moves the app's AX focused
    /// window. While a Chromium page has the keyboard its child window is
    /// the key window; AX clients must still get the cmux window, or they
    /// move the page off its pane.
    @Test func accessibilityClientsGetTheCmuxWindowNotAPageWindow() {
        let shell = Self.window(NSRect(x: 100, y: 100, width: 800, height: 600))
        let page = Self.window(NSRect(x: 340, y: 100, width: 560, height: 560), borderless: true)
        shell.addChildWindow(page, ordered: .above)
        #expect(CmuxApplication.accessibilityWindow(for: page) === shell)
        #expect(CmuxApplication.accessibilityWindow(for: shell) === shell)
        #expect(CmuxApplication.accessibilityWindow(for: nil) == nil)
        // App panels (palette) are their own AX windows.
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 10, height: 10), styleMask: [.borderless], backing: .buffered, defer: true)
        shell.addChildWindow(panel, ordered: .above)
        #expect(CmuxApplication.accessibilityWindow(for: panel) === panel)
        shell.removeChildWindow(page)
        shell.removeChildWindow(panel)
    }

    @Test func mismatchesNameHostsWithoutPagesAndStrayPages() {
        let host = ChildPageGeometry.Host(pane: "a", screenRect: CGRect(x: 340.5, y: 100, width: 559.5, height: 560))
        #expect(ChildPageGeometry.mismatches(hosts: [host], pages: [CGRect(x: 340, y: 100, width: 560, height: 560)]).isEmpty)
        let moved = ChildPageGeometry.mismatches(hosts: [host], pages: [CGRect(x: 0, y: 25, width: 720, height: 875)])
        #expect(moved.count == 2, "the pane lost its page and a page covers no pane")
        #expect(ChildPageGeometry.mismatches(hosts: [host], pages: []).count == 1)
    }
}
