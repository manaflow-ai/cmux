import AppKit
@testable import CmuxNextLayout
import Testing

/// Lawrence 2026-10-21 (workspace switch speed of light): the fleet's stall samples at 150 workspaces put 83 ms of
/// one switch in `NSWindow.setParentWindow` under `DividerMouseCatchers.update`: the old workspace's divider panels
/// left the window and the new one's joined it, and every child window change sends the window server the whole
/// child list. A switch (new divider ids, or the panels off for a workspace with no page and on again) must add or
/// remove no child window once the panels exist; the shown panels still match the areas.
@MainActor @Suite(.serialized) struct DividerCatcherSwitchTests {
    static func window() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 800, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
        window.orderFront(nil)
        return window
    }

    static func areas(_ prefix: String, _ count: Int) -> [LayoutMouseArea] {
        (0..<count).map { LayoutMouseArea(id: "\(prefix)\($0)", rect: CGRect(x: 100 + 150 * $0, y: 0, width: 8, height: 400), resizesColumns: true) }
    }

    static func children(_ window: NSWindow) -> Set<ObjectIdentifier> { Set((window.childWindows ?? []).map(ObjectIdentifier.init)) }

    @Test func aSwitchBetweenWorkspacesAddsOrRemovesNoChildWindow() {
        let window = Self.window()
        defer { window.close() }
        let catchers = DividerMouseCatchers(window: window)
        defer { catchers.teardown() }
        catchers.update(Self.areas("a", 2), active: true)
        let first = Self.children(window)
        #expect(first.count == 2)
        // Workspace b (other divider ids), then a workspace with no page (panels off), then a again.
        catchers.update(Self.areas("b", 2), active: true)
        #expect(Self.children(window) == first, "a switch to new divider ids changed the child windows")
        #expect(catchers.framesInWindow.keys.sorted() == ["b0", "b1"])
        catchers.update([], active: false)
        #expect(Self.children(window) == first, "turning the panels off changed the child windows")
        #expect(catchers.windowNumbers.isEmpty, "an inert panel still passes hover through")
        catchers.update(Self.areas("a", 1), active: true)
        #expect(Self.children(window) == first, "turning the panels on again changed the child windows")
        #expect(catchers.framesInWindow.keys.sorted() == ["a0"])
        #expect(catchers.windowNumbers.count == 1)
    }
}
