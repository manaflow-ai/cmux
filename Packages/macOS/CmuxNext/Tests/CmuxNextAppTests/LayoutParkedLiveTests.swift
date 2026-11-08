import AppKit
@testable import CmuxNextLayout
import CmuxNextDesign
import CmuxNextTestSupport
import Testing

/// A layout under a parked, unhidden workspace (`ParkingContainer`) is not live, as a hidden one is
/// not: no event monitor, no frame driver, no overlay plane. Showing it makes it live again.
@MainActor
@Suite(.closesItsWindows)
struct LayoutParkedLiveTests {
    final class Panes: LayoutPaneContentProvider {
        func makeContentView(for pane: PaneID) -> NSView { NSView() }
    }

    final class Container: NSView, ParkingContainer {
        var isParkedOffScreen = false
        func park(_ parked: Bool) {
            isParkedOffScreen = parked
            notifyParkingChange()
        }
    }

    @Test func parkingWithoutHidingTakesTheLayoutOffLine() {
        let provider = Panes()
        let model = LayoutModel(screens: [LayoutScreen(id: "s1", name: "s1", layout: .splits(.leaf("p1")))],
                                activeScreenID: "s1", focusedPane: "p1")
        let root = LayoutRootView(model: model, contentProvider: provider)
        let container = Container(frame: NSRect(x: 0, y: 0, width: 1200, height: 800))
        root.frame = container.bounds
        container.addSubview(root)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.borderless],
                              backing: .buffered, defer: true)
        defer { window.closeAfterTest() }
        window.contentView = container
        root.layoutSubtreeIfNeeded()
        #expect(root.isLive)
        container.park(true)
        #expect(!root.isLive)
        #expect(!root.driver.isAttached)
        #expect(root.paneCardsInWindow.isEmpty)
        container.park(false)
        #expect(root.isLive)
        #expect(root.driver.isAttached)
    }
}
