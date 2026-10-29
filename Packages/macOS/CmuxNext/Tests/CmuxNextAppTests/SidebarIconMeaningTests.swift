import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import Foundation
import Testing

/// The sidebar's icon-only marks say what they mean (affordance audit 2026-10-21): a machine
/// header's bare status dot names its state in the tooltip, the bell-slash on a muted workspace
/// says notifications are muted, the Priority bell names what its dot counts and keeps its
/// shortcut out of the label, and a tab row's unread dot is in the row's label.
@MainActor @Suite(.serialized) struct SidebarIconMeaningTests {
    private static func row(_ key: SidebarRowKey, section: SectionID, workspace: WorkspaceID? = nil) -> SidebarRow {
        SidebarRow(key: key, y: 0, height: 28, section: section, workspace: workspace, siblingIndex: 0,
                   isLastInGroup: true, isCollapsed: false, childCount: 1)
    }

    private static func header(_ machine: SidebarMachine, hostGroup: Bool = false) -> SectionHeaderRowView {
        var section = SidebarSection(kind: .machine(machine), nodes: [
            .workspace(SidebarWorkspace(id: WorkspaceID("ws-\(machine.id.rawValue)"), title: "api", lastActivity: Date())),
        ])
        section.isHostGroup = hostGroup
        let view = SectionHeaderRowView(key: .section(section.id))
        view.frame = NSRect(x: 0, y: 0, width: 260, height: 28)
        view.configure(section, row: row(.section(section.id), section: section.id))
        return view
    }

    // MARK: Machine header status dot

    /// Outside a remote group only a colored dot shows for Connected, Connecting and Offline: the
    /// tooltip says the state in words, and the label carries it too.
    @Test func aBareStatusDotNamesItsStateInTheTooltip() {
        let cases: [(SidebarMachine.Status, String)] = [
            (.connected, Strings.statusConnected), (.connecting, Strings.statusConnecting), (.offline, Strings.statusOffline),
        ]
        for (status, words) in cases {
            let view = Self.header(SidebarMachine(id: MachineID("box"), name: "build-box", kind: .ssh, status: status))
            #expect(view.themedToolTip == words, "\(status)")
            #expect(view.accessibilityLabel() == "build-box, \(words)", "\(status)")
        }
    }

    /// An optional update shows no words on the header (Lawrence 2026-10-21): the tooltip names it
    /// with its detail.
    @Test func anUpdateStateKeepsItsDetail() {
        let detail = "cmux-tui 0.9 on build-box lacks agent tabs."
        let view = Self.header(SidebarMachine(id: MachineID("box"), name: "build-box", kind: .ssh, status: .updateAvailable, detail: detail))
        #expect(view.themedToolTip == Strings.statusUpdateAvailable + " — " + detail)
        #expect(SectionHeaderRowView.statusToolTip(words: Strings.statusOffline, detail: detail, bareDot: true)
            == Strings.statusOffline + " — " + detail)
    }

    /// No dot (This Mac, connected), or the words beside the dot (a remote group): no tooltip
    /// repeats what shows.
    @Test func noTooltipWhereNothingIsLeftToSay() {
        #expect(Self.header(SidebarMachine(id: .local, name: "This Mac", kind: .local)).themedToolTip == nil)
        #expect(Self.header(SidebarMachine(id: MachineID("box"), name: "build-box", kind: .ssh, status: .offline), hostGroup: true)
            .themedToolTip == nil)
    }

    // MARK: Muted workspace mark

    @Test func theMutedMarkSaysNotificationsAreMuted() throws {
        let id = WorkspaceID("ws-muted")
        let model = SidebarModel(sections: [
            SidebarSection(kind: .machine(SidebarMachine(id: .local, name: "This Mac", kind: .local)), nodes: [
                .workspace(SidebarWorkspace(id: id, title: "api", lastActivity: Date(), muted: true)),
            ]),
        ])
        let sidebar = SidebarView(model: model, design: DesignSettings())
        sidebar.frame = NSRect(x: 0, y: 0, width: 260, height: 600)
        sidebar.layoutSubtreeIfNeeded()
        sidebar.list.reload(animated: false)
        let row = try #require(sidebar.list.rowViews[.workspace(id)] as? WorkspaceRowView)
        #expect(!row.mutedMark.isHidden)
        #expect(row.mutedMark.themedToolTip == Strings.notificationsMuted)
        #expect(row.accessibilityLabel()?.contains(Strings.notificationsMuted) == true)
    }

    // MARK: Priority bell

    /// The shortcut shows in the tooltip's shortcut slot, not glued into the label; while the dot
    /// shows, the label and tooltip say how many chats need the person.
    @Test func thePriorityBellNamesItsDotAndKeepsTheShortcutApart() {
        let sidebar = SidebarView(model: SidebarModel(sections: []), design: DesignSettings())
        let entries = (0..<3).map { SidebarPriorityEntry(id: "chat\($0)", title: "Chat \($0)", state: .needsYou) }
            + [SidebarPriorityEntry(id: "busy", title: "Busy", state: .working(since: nil))]
        sidebar.showPriority(SidebarPriorityPanel(entries: entries, shown: false, shortcut: "⌥⌘K"))
        let bell = sidebar.priorityButton
        let expected = Strings.priorityShow + ", " + Strings.priorityAttentionCount(3)
        #expect(bell.accessibilityLabel() == expected)
        #expect(bell.themedToolTip == expected)
        #expect(bell.themedToolTipShortcut == "⌥⌘K")
        #expect(bell.accessibilityLabel()?.contains("⌥⌘K") == false)

        // Shown and nothing out of sight: no dot, the plain label.
        sidebar.showPriority(SidebarPriorityPanel(entries: entries, shown: true, shortcut: "⌥⌘K"))
        #expect(bell.accessibilityLabel() == Strings.priorityHide)
        #expect(bell.themedToolTipShortcut == "⌥⌘K")
    }

    /// The dot also lights for a chat that finished unseen: the label never calls a Done chat
    /// one that needs you.
    @Test func aDoneOnlyBellSaysNeedsAttentionNotNeedsYou() {
        let sidebar = SidebarView(model: SidebarModel(sections: []), design: DesignSettings())
        sidebar.showPriority(SidebarPriorityPanel(entries: [SidebarPriorityEntry(id: "done", title: "Done", state: .done)], shown: false))
        let label = sidebar.priorityButton.accessibilityLabel() ?? ""
        #expect(label == Strings.priorityShow + ", " + Strings.priorityAttentionCount(1))
        #expect(!label.contains(Strings.priorityNeedsYou))
    }

    // MARK: Update Available button

    /// Leo 2026-10-28: "Also, the update button, don't put at the top. Put on the bottom. The bottom has room. The
    /// bottom of the sidebar area." The quiet Update Available button sits at the footer line's end, on the Search
    /// button's line, inside the sidebar; the titlebar row keeps only the bell and +, and the spaces strip ends before it.
    @Test(arguments: [false, true])
    func theUpdateButtonSitsAtTheBottom(_ noFade: Bool) {
        let design = DesignSettings()
        design.sidebarSections.noFade = noFade
        let sidebar = SidebarView(model: SidebarModel(sections: []), design: design)
        sidebar.showPriority(SidebarPriorityPanel(entries: [], shown: false))
        sidebar.frame = NSRect(x: 0, y: 0, width: 260, height: 600)
        sidebar.layoutSubtreeIfNeeded()
        let bellBefore = sidebar.priorityButton.frame
        sidebar.showUpdateAvailable("Update Available")
        sidebar.layoutSubtreeIfNeeded()
        let update = sidebar.updateAvailableButton, bounds = sidebar.bounds
        #expect(!update.isHidden)
        #expect(update.accessibilityLabel() == "Update Available")
        #expect(sidebar.priorityButton.frame == bellBefore, "the update button moved the bell")
        // The sidebar is flipped: the bottom line is its largest y.
        #expect(update.frame.midY > bounds.height * 0.85, "the update button is not on the bottom line: \(update.frame) in \(bounds)")
        #expect(update.frame.maxY <= bounds.maxY && update.frame.maxX <= bounds.maxX, "the update button leaves the sidebar")
        if !sidebar.searchButton.isHidden {
            // Search holds the line's right end (f004cef0aa9); the update button sits just left of it, on its line.
            #expect(abs(update.frame.midY - sidebar.searchButton.frame.midY) <= 1, "the update button is off the Search button's line")
            #expect(abs(sidebar.searchButton.frame.minX - Metrics.space1 - update.frame.maxX) <= 0.5, "the update button is not just left of Search")
        }
        // Codex review: a sidebar too narrow for both never covers Search or the avatar; the update button steps out of the line.
        sidebar.frame.size.width = 80
        sidebar.layoutSubtreeIfNeeded()
        if !sidebar.searchButton.isHidden {
            #expect(update.frame == .zero || update.frame.maxX <= sidebar.searchButton.frame.minX, "the update button covers Search at 80 pt")
        }
        sidebar.showUpdateAvailable(nil)
        #expect(update.isHidden)
    }

    // MARK: Tab row unread dot

    @Test func anUnreadTabRowSaysUnread() {
        let workspace = WorkspaceID("ws-tabs")
        let section = SectionID.machine(.local)
        for unread in [true, false] {
            let tab = SidebarTab(id: TabID("tab-zsh"), title: "zsh", isUnread: unread)
            let key = SidebarRowKey.tab(workspace, tab.id)
            let view = SidebarTabRowView(key: key)
            view.configure(tab, row: Self.row(key, section: section, workspace: workspace))
            #expect(view.accessibilityLabel() == (unread ? "zsh, \(Strings.unreadDot)" : "zsh"))
        }
    }
}
