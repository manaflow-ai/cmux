import AppKit
import Testing
@testable import CmuxNextSidebar

/// Stability rule (Leo, 2026-10-05): hover never moves or remounts known
/// chrome. A header's hover controls keep their slots, so its name doesn't
/// re-truncate, and a titled section's chevron fades instead of mounting.
@MainActor @Suite struct SidebarHoverStabilityTests {
    final class Harness {
        let model = SidebarModel(sections: fixture(), activeWorkspaceID: id("a"))
        let sidebar: SidebarView
        let window = NSWindow(contentRect: NSRect(x: -30_000, y: -30_000, width: 700, height: 700), styleMask: [.borderless],
                              backing: .buffered, defer: false)

        init() {
            sidebar = SidebarView(model: model)
            window.isReleasedWhenClosed = false
            // Narrow enough that header names truncate.
            sidebar.frame = NSRect(x: 0, y: 0, width: 120, height: 700)
            window.contentView?.addSubview(sidebar)
            model.send(.renameGroup(g1, "A group name long enough to truncate"))
            sidebar.layoutSubtreeIfNeeded()
            sidebar.list.reload(animated: false)
        }

        func view<V: SidebarRowView>(_ key: SidebarRowKey, as: V.Type) throws -> V {
            let view = try #require(sidebar.list.rowViews[key] as? V)
            view.layoutSubtreeIfNeeded()
            return view
        }
    }

    @Test func aGroupHeadersNameKeepsItsWidthOnHover() throws {
        let h = Harness()
        defer { h.window.close() }
        let view = try h.view(.group(g1), as: GroupHeaderRowView.self)
        let rest = view.titleFrame
        view.isHovered = true
        view.layoutSubtreeIfNeeded()
        #expect(view.titleFrame == rest)
    }

    @Test func aSectionHeadersNameKeepsItsWidthOnHover() throws {
        let h = Harness()
        defer { h.window.close() }
        // The one list's "Projects" header (`sidebar.groupByComputer` off).
        let view = try h.view(.section(local), as: SectionHeaderRowView.self)
        let rest = view.nameFrame
        view.isHovered = true
        view.layoutSubtreeIfNeeded()
        #expect(view.nameFrame == rest)
    }

    /// An unread row's x takes the badge's slot on hover, so the name and
    /// the activity glyph beside it stay put.
    @Test(arguments: [UnreadState.dot, .count(3), .count(128)])
    func anUnreadRowsNameKeepsItsWidthOnHover(_ unread: UnreadState) throws {
        var sections = fixture()
        sections[1].nodes[0] = .workspace(SidebarWorkspace(id: id("a"), title: "Unread work", unread: unread))
        let h = MinimalChromeTests.Harness(sections: sections)
        let row = try #require(h.sidebar.list.rowViews[.workspace(id("a"))] as? WorkspaceRowView)
        row.layoutSubtreeIfNeeded()
        let rest = row.titleFrame
        row.isHovered = true
        row.layoutSubtreeIfNeeded()
        #expect(row.titleFrame == rest)
        #expect(!row.closeButton.isHidden)
        row.isHovered = false
        row.layoutSubtreeIfNeeded()
        #expect(row.titleFrame == rest)
    }

    @Test func aTitledSectionsChevronFadesInsteadOfMounting() {
        let view = SidebarSectionHeaderView(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        view.configure(title: "Apps", collapsed: false)
        #expect(!view.chevron.isHidden)
        #expect(view.chevron.alphaValue == 0)
        view.isHovered = true
        #expect(!view.chevron.isHidden)
        #expect(view.chevron.alphaValue == 1)
    }
}
