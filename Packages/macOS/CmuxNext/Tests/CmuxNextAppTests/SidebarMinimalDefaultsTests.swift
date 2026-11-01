import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import Foundation
import Testing

/// Lawrence 2026-10-21: "bring the spinner back by default, dont show times in sidebar. remove
/// merge indicator by default as well. sidebar must be kept minimal by default", then "1h 10m"
/// next to a busy row's spinner ("that counts as a time"), titles that start at two x's ("weird
/// spacing") and "Chief • Update available" on a group header. By default a workspace row is its
/// name and one state mark (the spinner, the unread dot): no running time, no pull request badge,
/// no agent words, no status or log line; a title without an icon starts at the row inset (Lawrence
/// 2026-10-23 took back the empty icon slot); a machine header never prints "Update available". Each stays a setting.
@MainActor @Suite(.serialized) struct SidebarMinimalDefaultsTests {
    private static let busy = WorkspaceID("ws-busy")
    private static let favicon = WorkspaceID("ws-favicon")
    private static let plain = WorkspaceID("ws-plain")
    private static let reported = WorkspaceID("ws-reported")

    private static func sidebar(showTimestamps: Bool? = nil, minimal: Bool = false, width: CGFloat = 320) -> SidebarView {
        let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
        var busyRow = SidebarWorkspace(id: busy, title: "Panes", lastActivity: Date(), agentWorking: true, kind: .terminal,
                                       activity: .working(progress: nil))
        busyRow.detail.activitySince = Date().addingTimeInterval(-70 * 60)
        var iconRow = SidebarWorkspace(id: favicon, title: "workspace-108", kind: .browser)
        iconRow.icon = .symbol("play.rectangle.fill")
        let plainRow = SidebarWorkspace(id: plain, title: "workspace-114", kind: .terminal)
        var reportedRow = SidebarWorkspace(id: reported, title: "build", kind: .terminal)
        reportedRow.reported = SidebarWorkspaceStatus(entries: [.init(key: "claude", text: "Running")],
                                                      log: .init(level: .info, text: "compiling"))
        let model = SidebarModel(sections: [
            SidebarSection(kind: .machine(machine), nodes: [.workspace(busyRow), .workspace(iconRow), .workspace(plainRow),
                                                            .workspace(reportedRow)]),
        ])
        let design = DesignSettings()
        if let showTimestamps { design.sidebarSections.showTimestamps = showTimestamps }
        design.sidebarSections.minimal = minimal
        let sidebar = SidebarView(model: model, design: design)
        sidebar.frame = NSRect(x: 0, y: 0, width: width, height: 600)
        sidebar.renderNow()
        sidebar.layoutSubtreeIfNeeded()
        sidebar.list.reload(animated: false)
        sidebar.list.rowViews.values.forEach { $0.layoutSubtreeIfNeeded() }
        return sidebar
    }

    private static func row(_ sidebar: SidebarView, _ id: WorkspaceID) throws -> WorkspaceRowView {
        try #require(sidebar.list.rowViews[.workspace(id)] as? WorkspaceRowView)
    }

    // MARK: Times

    /// "1h 10m" beside the spinner is a time: no row draws one by default (#23812 removed the
    /// running time; this guards its age too), in every mode.
    @Test(arguments: [false, true])
    func aBusyRowDrawsNoTimeByDefault(minimal: Bool) throws {
        let row = try Self.row(Self.sidebar(minimal: minimal), Self.busy)
        #expect(row.timeLabel.isHidden || row.timeLabel.stringValue.isEmpty, "a time draws: \(row.timeLabel.stringValue)")
    }

    /// The spinner stays: the row's one state mark.
    @Test func aBusyRowStillSpins() throws {
        let row = try Self.row(Self.sidebar(), Self.busy)
        #expect(row.rowBadge.states == [.working(progress: nil)] || row.activityState.isWorking)
    }

    // MARK: Decorations

    @Test func decorationTogglesAreOffByDefault() {
        // The pull request (merge) badge follows its row element (#23989), off for every kind.
        #expect(WorkspaceRowKind.allCases.allSatisfy { !WorkspaceRowPreferences.defaults.resolved(for: $0).shows(.pullRequest) })
        #expect(SidebarTunables.nowLine.defaultValue == false, "the \"Now: …\" line")
        #expect(SidebarSectionsPreferences.defaults.showTimestamps == false)
    }

    /// The default row set is the icon and the state marks; status entries and the log line are opt-in.
    @Test func theDefaultRowIsNameAndState() {
        let shown = WorkspaceRowPreferences.defaults.base.shown
        #expect(shown == [.icon, .working, .progress], "\(shown)")
    }

    @Test func aReportedStatusDrawsNoTextByDefault() throws {
        let row = try Self.row(Self.sidebar(), Self.reported)
        #expect(row.timeLabel.isHidden || row.timeLabel.stringValue.isEmpty, "status words: \(row.timeLabel.stringValue)")
        #expect(row.subtitle.stringValue.isEmpty, "a second line: \(row.subtitle.stringValue)")
    }

    // MARK: Alignment

    /// A row without an icon starts its title at the leading inset; a row with one starts it after the icon
    /// (Lawrence 2026-10-23: "text needs to be as left as possible (how it originally was)").
    @Test(arguments: [false, true])
    func aTitleWithoutAnIconStartsAtTheInset(minimal: Bool) throws {
        let sidebar = Self.sidebar(minimal: minimal)
        for id in [Self.busy, Self.plain, Self.reported] {
            let row = try Self.row(sidebar, id)
            #expect(row.title.frame.minX == SidebarStyle.horizontalInset, "\(id): title at \(row.title.frame.minX) pt")
        }
        let withIcon = try Self.row(sidebar, Self.favicon)
        #expect(!withIcon.icon.isHidden && withIcon.icon.frame.maxX <= withIcon.title.frame.minX + WorkspaceRowView.labelInset)
    }

    /// Rows with and without an icon are equally tall.
    @Test func rowsWithAndWithoutAnIconHaveOneHeight() throws {
        let sidebar = Self.sidebar()
        let heights = try [Self.busy, Self.favicon, Self.plain, Self.reported].map { try Self.row(sidebar, $0).frame.height }
        #expect(Set(heights).count == 1, "row heights: \(heights)")
    }

    // MARK: Headers

    /// "Update available" is not a header's business: the name only, the words in its tooltip.
    @Test(arguments: [false, true])
    func aMachineHeaderNeverSaysUpdateAvailable(hostGroup: Bool) {
        #expect(SectionHeaderRowView.statusText(.updateAvailable, hostGroup: hostGroup) != Strings.statusUpdateAvailable)
        #expect(SectionHeaderRowView.statusText(.updateAvailable, hostGroup: false) == nil)
        let header = SectionHeaderRowView(key: .section(SidebarSection(kind: .machine(SidebarMachine(id: MachineID("chief"), name: "Chief", kind: .server)), nodes: []).id))
        let machine = SidebarMachine(id: MachineID("chief"), name: "Chief", kind: .server, status: .updateAvailable,
                                     detail: "Built before this app")
        let section = SidebarSection(kind: .machine(machine), nodes: [])
        header.configure(section, row: SidebarRow(key: .section(section.id), y: 0, height: 28, section: section.id, group: nil,
                                                  siblingIndex: 0, parentIndex: nil, isLastInGroup: false, isCollapsed: false,
                                                  childCount: 0, groupColor: nil))
        #expect(header.badgeText == nil)
        // #26786 gives remote machine headers the shared connected-state green dot.
        // An optional update adds no status words; its details remain in the tooltip.
        #expect(header.statusTone == .success)
        #expect(header.themedToolTip?.contains(Strings.statusUpdateAvailable) == true, "the tooltip still says it")
    }
}
