import AppKit
import CmuxNextDesign
@testable import CmuxNextSidebar
import Testing
import CmuxNextTestSupport

/// Chrome-parity p03-rendering-062 (MQ-damage-owners, CmuxNextSidebar): a sidebar view asks for a paint
/// or a layout only when a value it draws from changed. A layout pass sets frames and repaints nothing
/// (the rows' `updateLayer` sets colors only, task 060); an equal configure, a hover that moves nothing
/// and a theme repaint of unchanged text ask for no layout. Chromium keeps the same split: paint is
/// invalidated by the properties that changed, not by a layout (third_party/blink/renderer/core/paint/
/// paint_invalidator.cc), and `cc::Layer::SetNeedsDisplayRect` is called for changed contents only.
@MainActor @Suite(.serialized, .renderHooks)
struct SidebarInvalidationTests {
    /// The rows whose `layout()` marked them for display on every pass (a resize repainted each).
    private static let laidOutRows: [SidebarRowView.Type] = [
        EmptySectionRowView.self, FolderHeaderRowView.self, StatusHeaderRowView.self,
        SidebarDoneFoldRowView.self, GroupHeaderRowView.self, SectionHeaderRowView.self,
    ]

    private static func row(_ type: SidebarRowView.Type) -> SidebarRowView {
        type.init(key: .workspace(WorkspaceID("ws-invalidation")))
    }

    /// `view` in a window, laid out at `size`, with no paint pending.
    private func hosted(_ view: NSView, size: NSSize) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: NSSize(width: 400, height: 200)),
                              styleMask: .borderless, backing: .buffered, defer: false)
        // `close()` would release a window the test still holds (a segfault on the fleet).
        window.isReleasedWhenClosed = false
        window.contentView?.addSubview(view)
        view.frame = NSRect(origin: .zero, size: size)
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        view.needsDisplay = false
        return window
    }

    /// A resize lays a header row out again and paints nothing: its colors did not change.
    @Test func aRowResizeLaysOutWithoutARepaint() {
        for type in Self.laidOutRows {
            let row = Self.row(type)
            let window = hosted(row, size: NSSize(width: 240, height: 28))
            defer { window.close() }
            row.setFrameSize(NSSize(width: 300, height: 28))
            #expect(row.needsLayout, "\(type): a new size asks for layout")
            row.layoutSubtreeIfNeeded()
            #expect(!row.needsLayout, "\(type)")
            #expect(!row.needsDisplay, "\(type): its layout asked for a repaint")
        }
    }

    /// A badge's and an icon's layout place their parts and paint nothing.
    @Test func aBadgeAndAnIconLayOutWithoutARepaint() {
        let badge = UnreadBadgeView(frame: .zero)
        badge.configure(.count(3))
        let icon = SidebarIconView(frame: .zero)
        icon.configure(icon: .emoji("🙂", chip: .blue))
        for view in [badge, icon] as [NSView] {
            let window = hosted(view, size: NSSize(width: 16, height: 16))
            defer { window.close() }
            view.setFrameSize(NSSize(width: 20, height: 20))
            view.needsLayout = true
            view.layoutSubtreeIfNeeded()
            #expect(!view.needsDisplay, "\(type(of: view)): its layout asked for a repaint")
        }
    }

    /// A row configures its badge, presence dots and status block on every content change: the same
    /// values ask for no paint and no layout; a new value asks for both.
    @Test func anEqualConfigureAsksForNothing() {
        let badge = UnreadBadgeView(frame: .zero)
        let dots = PresenceDotsView(frame: .zero)
        let status = WorkspaceStatusView(frame: NSRect(x: 0, y: 0, width: 240, height: 60))
        let agents = [SidebarPresence(id: "p1", name: "Claude Code", activity: .editing)]
        let reported = SidebarWorkspaceStatus(entries: [.init(key: "build", text: "Building")])
        func configureAll() {
            badge.configure(.count(3))
            dots.configure(agents)
            status.configure(reported, reservesBar: false)
        }
        configureAll()
        for view in [badge, dots, status] as [NSView] {
            view.layoutSubtreeIfNeeded()
            view.needsDisplay = false
        }
        configureAll()
        for view in [badge, dots, status] as [NSView] {
            #expect(!view.needsLayout, "\(type(of: view))")
            #expect(!view.needsDisplay, "\(type(of: view))")
        }
        badge.configure(.count(4))
        #expect(badge.needsLayout && badge.needsDisplay)
        dots.configure([])
        #expect(dots.isHidden && dots.needsLayout && dots.needsDisplay)
        status.configure(reported, reservesBar: true)
        #expect(status.needsLayout && status.needsDisplay)
    }

    /// A fresh badge and dot row show nothing until configured with something to show.
    @Test func freshBadgeAndDotsStayHiddenForNothing() {
        let badge = UnreadBadgeView(frame: .zero)
        badge.configure(.none)
        #expect(badge.isHidden)
        let dots = PresenceDotsView(frame: .zero)
        dots.configure([])
        #expect(dots.isHidden)
    }

    /// The status block lays its pills out after the paint that builds new text; a repaint of the same
    /// text (a theme change) keeps every width and asks for no layout.
    @Test func aStatusRepaintLaysOutOnlyNewText() {
        let view = WorkspaceStatusView(frame: NSRect(x: 0, y: 0, width: 240, height: 60))
        view.configure(SidebarWorkspaceStatus(entries: [.init(key: "build", text: "Building")]), reservesBar: false)
        view.layoutSubtreeIfNeeded()
        view.updateLayer()
        #expect(view.needsLayout, "the text's first paint lays the pills out")
        view.layoutSubtreeIfNeeded()
        view.updateLayer()
        #expect(!view.needsLayout, "a repaint of the same text asked for layout")
    }

    /// A section header's hover paints its fill and lays nothing out: its controls keep their slots.
    @Test func aSectionHeaderHoverRepaintsWithoutALayout() {
        let header = SectionHeaderRowView(key: .workspace(WorkspaceID("ws-hover")))
        let window = hosted(header, size: NSSize(width: 240, height: 28))
        defer { window.close() }
        header.isHovered = true
        #expect(header.needsDisplay)
        #expect(!header.needsLayout)
        header.allowsAdd = false
        #expect(header.needsLayout, "the add slot follows `allowsAdd`")
    }

    /// Reuse shows the title again on every recycled row: only a rename's start or end lays it out.
    @Test func reuseLaysOutNoRowThatWasNotRenaming() {
        let header = GroupHeaderRowView(key: .workspace(WorkspaceID("ws-rename")))
        let window = hosted(header, size: NSSize(width: 240, height: 28))
        defer { window.close() }
        header.setTitleHidden(false)
        #expect(!header.needsLayout)
        header.setTitleHidden(true)
        #expect(header.needsLayout)
    }

    /// RenderStats' count of the owners' `updateLayer` calls (the `debug.damage` damage rects) over a
    /// resize: 0. Before this change each row painted once per resize step.
    @Test func renderStatsCountsNoResizeDamage() async {
        let stats = RenderStats()
        guard stats.arm() else { return } // a build without the hooks
        guard await stats.ready() else {
            stats.disarm()
            _ = await stats.ready()
            return
        }
        for type in Self.laidOutRows {
            let row = Self.row(type)
            let window = hosted(row, size: NSSize(width: 240, height: 28))
            defer { window.close() }
            stats.reset()
            for width in [260.0, 280.0, 300.0] {
                row.setFrameSize(NSSize(width: width, height: 28))
                row.layoutSubtreeIfNeeded()
                row.displayIfNeeded()
            }
            #expect(Self.damage(stats, type) == 0, "\(type) repainted on a resize")
            // The count works: a paint asked for is one damage rect.
            row.needsDisplay = true
            row.displayIfNeeded()
            #expect(Self.damage(stats, type) == 1, "\(type)")
        }
        // Every original IMP back before the next suite arms its own instance.
        stats.disarm()
        _ = await stats.ready()
    }

    private static func damage(_ stats: RenderStats, _ type: AnyClass) -> Int {
        stats.owners().first { $0.key == RenderStats.classKey(type) }?.totals[.damageRects] ?? 0
    }
}
