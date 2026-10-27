import AppKit
import CmuxNextDesign
@testable import CmuxNextSidebar
import Testing

/// Chrome-parity p03-rendering-060 (MQ-redraw-policy): a sidebar view that paints in `updateLayer`
/// repaints on `needsDisplay` only, never because its size changed. AppKit's default
/// (`.duringViewResize`) ran every row's `updateLayer` on each frame of a sidebar or split resize,
/// although the rows only set layer colors. Geometry that follows the size (a badge's radius, a
/// group line's shape) is set in `layout()`, which a size change asks for, so nothing shows stale
/// or stretched. Chromium does the same split: paint invalidation is separate from a layout's size
/// change (third_party/blink/renderer/core/paint/paint_invalidator.cc).
@MainActor @Suite(.serialized)
struct SidebarRedrawPolicyTests {
    private static let rowTypes: [SidebarRowView.Type] = [
        WorkspaceRowView.self, GroupHeaderRowView.self, SectionHeaderRowView.self, StatusHeaderRowView.self,
        FolderHeaderRowView.self, EmptyGroupRowView.self, EmptySectionRowView.self, SidebarDoneFoldRowView.self,
        SidebarItemListRowView.self, SidebarTabRowView.self,
    ]

    private static func paintedViews() -> [NSView] {
        [
            PresenceDotsView(frame: .zero), SidebarItemRowView(frame: .zero), SidebarRegionView(region: .top),
            SidebarSectionHeaderView(frame: .zero), SidebarCardTextButton(frame: .zero), GroupLineView(),
            SidebarIconButton(symbol: "pin", label: "Pin"), SidebarIconView(frame: .zero),
            SidebarNowPlayingPlayButton(frame: .zero), SidebarUpdateButton(frame: .zero),
            SidebarUpdateCardView(frame: .zero), SidebarUpdateToggle(frame: .zero), SidebarEditBar(),
            UnreadBadgeView(frame: .zero), WorkspaceStatusView(frame: .zero), SidebarPriorityPanelView(frame: .zero),
        ]
    }

    private func hosted(_ view: NSView, size: NSSize) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: NSSize(width: 320, height: 200)),
                              styleMask: .borderless, backing: .buffered, defer: true)
        // `close()` would release a window the test still holds (a segfault on the fleet).
        window.isReleasedWhenClosed = false
        window.contentView?.addSubview(view)
        view.frame = NSRect(origin: .zero, size: size)
        view.needsLayout = true
        view.layoutSubtreeIfNeeded()
        return window
    }

    @Test func everyRowRepaintsOnSetNeedsDisplayOnly() {
        for type in Self.rowTypes {
            let row = type.init(key: .workspace(WorkspaceID("ws-redraw")))
            #expect(row.layerContentsRedrawPolicy == .onSetNeedsDisplay, "\(type)")
        }
    }

    /// The top block's row is a container: its region paints, the row itself has nothing to draw.
    @Test func blockRowNeverRedraws() {
        let row = SidebarBlockRowView(key: .workspace(WorkspaceID("ws-block")))
        #expect(row.layerContentsRedrawPolicy == .never)
    }

    @Test func everyPaintedViewRepaintsOnSetNeedsDisplayOnly() {
        for view in Self.paintedViews() {
            #expect(view.layerContentsRedrawPolicy == .onSetNeedsDisplay, "\(type(of: view))")
        }
    }

    /// A dot badge stays round at its new size with no repaint: the radius is layout's.
    @Test func unreadBadgeRadiusFollowsSizeThroughLayout() {
        let badge = UnreadBadgeView(frame: .zero)
        badge.configure(.dot)
        let window = hosted(badge, size: NSSize(width: 8, height: 8))
        defer { window.close() }
        #expect(badge.layer?.cornerRadius == 4)
        badge.setFrameSize(NSSize(width: 12, height: 12))
        badge.layoutSubtreeIfNeeded()
        #expect(badge.layer?.cornerRadius == 6)
    }

    /// The play disc stays a circle at its new size with no repaint.
    @Test func playButtonRadiusFollowsSizeThroughLayout() {
        let button = SidebarNowPlayingPlayButton(frame: .zero)
        let window = hosted(button, size: NSSize(width: 20, height: 20))
        defer { window.close() }
        #expect(button.layer?.cornerRadius == 10)
        button.setFrameSize(NSSize(width: 28, height: 28))
        button.layoutSubtreeIfNeeded()
        #expect(button.layer?.cornerRadius == 14)
    }

    /// A group line's rail takes its new width on layout, with no repaint.
    @Test func groupLineShapeFollowsWidthThroughLayout() {
        let line = GroupLineView()
        let window = hosted(line, size: NSSize(width: 2, height: 40))
        defer { window.close() }
        #expect(line.railShape.frame.width == 2)
        line.setFrameSize(NSSize(width: 3, height: 40))
        line.layoutSubtreeIfNeeded()
        #expect(line.railShape.frame.width == 3)
    }
}
