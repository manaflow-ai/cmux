import AppKit
import CmuxNextDesign
@testable import CmuxNextPalette
@testable import CmuxNextSidebar
import Testing

/// A view's `.inVisibleRect` tracking area is added once, in its init, and lives as long
/// as the view. AppKit keeps its rect equal to the visible rect, so a resize, a scroll or a window move
/// rebuilds nothing (Chromium's `BridgedContentView` adds its one `NSTrackingInVisibleRect` area in
/// `-initWithBridge:bounds:`, components/remote_cocoa/app_shim/bridged_content_view.mm).
@MainActor @Suite(.serialized) struct TrackingAreaOnceTests {
    /// The view's own `.inVisibleRect` areas, by identity (a tooltip's or a `PointerHover`'s area has
    /// another owner).
    private static func visibleRectAreas(_ view: NSView) -> [ObjectIdentifier] {
        view.trackingAreas.filter { $0.owner === view && $0.options.contains(.inVisibleRect) }.map(ObjectIdentifier.init)
    }

    /// Puts `view` in a window, then resizes it, moves it and has AppKit's update run as a live resize
    /// would: the one area made in init is the one left.
    private static func expectAreaSurvives(_ view: NSView, _ name: String) {
        let made = visibleRectAreas(view)
        #expect(made.count == 1, "\(name): one .inVisibleRect area from init")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView?.addSubview(view)
        for step in 1...5 {
            view.frame = NSRect(x: CGFloat(step), y: CGFloat(step), width: 100 + CGFloat(step) * 10, height: 30)
            view.updateTrackingAreas()
        }
        window.setContentSize(NSSize(width: 520, height: 360))
        view.removeFromSuperview()
        window.contentView?.addSubview(view)
        view.updateTrackingAreas()
        #expect(visibleRectAreas(view) == made, "\(name): the same area after resizes and a window move")
    }

    @Test func sidebarViewsKeepTheirOneArea() {
        Self.expectAreaSurvives(SidebarCardTextButton(frame: NSRect(x: 0, y: 0, width: 80, height: 24)), "card text button")
        Self.expectAreaSurvives(SidebarUpdateButton(frame: NSRect(x: 0, y: 0, width: 80, height: 24)), "update button")
        Self.expectAreaSurvives(SidebarChatHistoryRow(frame: NSRect(x: 0, y: 0, width: 200, height: 28)), "chat history row")
        Self.expectAreaSurvives(SidebarPullRequestCardRow(frame: NSRect(x: 0, y: 0, width: 200, height: 40)), "pull request row")
    }

    @Test func paletteTableKeepsItsOneArea() {
        Self.expectAreaSurvives(PaletteTableView(frame: NSRect(x: 0, y: 0, width: 300, height: 200)), "palette table")
    }

    /// A row that takes no pointer has no area at all; an interactive one has one from init.
    @Test func popupRowTracksOnlyWhenInteractive() {
        #expect(Self.visibleRectAreas(PopupRowView(leading: nil, title: "Note", interactive: false)).isEmpty)
        Self.expectAreaSurvives(PopupRowView(leading: nil, title: "Copy"), "interactive popup row")
    }

    /// The Energy Saver leaf's area is the app-active one from init, with no update needed first.
    @Test func energyLeafAreaIsActiveInTheActiveApp() {
        let leaf = SidebarEnergyIndicator(frame: NSRect(x: 0, y: 0, width: 24, height: 24))
        let options = leaf.trackingAreas.filter { $0.owner === leaf }.map(\.options)
        #expect(options.count == 1)
        #expect(options.allSatisfy { $0.contains(.activeInActiveApp) && $0.contains(.inVisibleRect) })
    }
}
