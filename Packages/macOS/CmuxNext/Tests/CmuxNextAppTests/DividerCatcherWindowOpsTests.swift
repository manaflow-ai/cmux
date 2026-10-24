import AppKit
@testable import CmuxNextLayout
import Testing

/// Every-action sweep, group divider-mouse-catchers (2026-10-23, 33 actions): in STRESS a confirmation
/// dialog (closeTab of a busy terminal) and a workspace switch (closeWorkspace) spent 85 to 100 ms on
/// the main thread in `DividerMouseCatchers.update`: hiding the catchers under a dialog removed and
/// ordered out every panel, showing them again re-added each one, and a new layout's divider ids made
/// new panels and dropped the old. Window ordering and window creation are window server round trips.
/// The catcher panels are a pool: a panel no area needs is parked in place (it lets the mouse through)
/// and taken again by the next area, so after the first placement no update orders or makes a window.
@MainActor @Suite struct DividerCatcherWindowOpsTests {
    static func areas(_ ids: [String], x: CGFloat = 200) -> [LayoutMouseArea] {
        ids.enumerated().map { index, id in LayoutMouseArea(id: id, rect: CGRect(x: x + CGFloat(index) * 300, y: 0, width: 8, height: 400), resizesColumns: true) }
    }

    @Test func aDialogAndAWorkspaceSwitchOrderAndMakeNoWindow() {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: CGRect(x: 100, y: 100, width: 1000, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.orderFront(nil)
        let catchers = DividerMouseCatchers(window: window)
        defer {
            catchers.teardown()
            window.close()
        }
        catchers.update(Self.areas(["split:a", "split:b"]), active: true)
        #expect(catchers.coveredAreaIDs == ["split:a", "split:b"])
        let (orders, made) = (catchers.windowOrderings, catchers.panelsMade)
        // A dialog blocks the whole window: no divider takes the mouse under it.
        catchers.update(Self.areas(["split:a", "split:b"]), active: false)
        #expect(catchers.coveredAreaIDs.isEmpty, "no catcher takes the mouse under the dialog")
        catchers.update(Self.areas(["split:a", "split:b"]), active: true)
        // Another workspace shows: its dividers have other ids and places.
        catchers.update(Self.areas(["split:c", "split:d"], x: 260), active: true)
        #expect(catchers.coveredAreaIDs == ["split:c", "split:d"], "the new layout's dividers have their catchers")
        #expect(Set(catchers.framesInWindow.keys) == ["split:c", "split:d"])
        #expect(catchers.windowOrderings == orders, "no window ordered: \(catchers.windowOrderings - orders)")
        #expect(catchers.panelsMade == made, "no window made: \(catchers.panelsMade - made)")
    }
}
