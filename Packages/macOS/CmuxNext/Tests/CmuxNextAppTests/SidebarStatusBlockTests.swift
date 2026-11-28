import CmuxNextBridge
@testable import CmuxNextDaemon
import CmuxNextSettings
@testable import CmuxNextSidebar
import Testing

/// Classic's status block in workspace rows (#16431): with default settings, a workspace whose
/// agents report status, a log line or progress (`cmux workspace status|log|progress`) draws them
/// under its name, while a workspace that reports nothing stays a one-line row. Turning the
/// elements off in cmux.json (`sidebar.workspaceRow.*`) hides the block.
@MainActor
struct SidebarStatusBlockTests {
    static let reported = ResourceID(rawValue: "ws-reported")
    static let quiet = ResourceID(rawValue: "ws-quiet")

    /// The sidebar layout of a store with one reporting and one quiet workspace under `settings`.
    func layout(_ settings: [String: CmuxNextSettings.JSONValue] = [:]) -> (layout: SidebarLayout, reported: SidebarRow, quiet: SidebarRow) {
        let store = DaemonStore()
        store.apply(snapshot: DaemonTree(workspaces: [
            WorkspaceSnapshot(id: 1, key: nil, resourceID: Self.reported, name: "build"),
            WorkspaceSnapshot(id: 2, key: nil, resourceID: Self.quiet, name: "notes"),
        ]))
        var mirror = SessionStateMirror()
        mirror.workspaceStatus[Self.reported] = WorkspaceStatus(
            workspaceID: Self.reported,
            entries: [WorkspaceStatus.Entry(key: "build", text: "Building", icon: "hammer", color: "#ff8800"),
                      WorkspaceStatus.Entry(key: "tests", text: "412 passed", color: "green")],
            progress: WorkspaceStatus.Progress(value: 0.4, label: "Linking"),
            logCount: 1, lastLog: WorkspaceStatus.LogLine(level: "warning", text: "2 warnings"))
        store.session.apply(.snapshot(mirror), in: store)

        let sections = SidebarMapping.shared.sections(store.sidebarSections,
                                                      machine: SidebarMachine(id: .local, name: "This Mac", kind: .local))
        var diagnostics: [SettingsDiagnostic] = []
        var options = SidebarLayoutOptions()
        options.workspaceRow = WorkspaceRowSetting().parse(
            .object(["sidebar": .object(["workspaceRow": .object(settings)])]), diagnostics: &diagnostics)
        let layout = SidebarLayout.make(sections: sections, metrics: .standard, options: options)
        let ids = Dictionary(uniqueKeysWithValues: sections.flatMap(\.workspaces).map { ($0.title, $0.id) })
        let reported = layout.row(for: .workspace(ids["build"]!))!
        let quiet = layout.row(for: .workspace(ids["notes"]!))!
        return (layout, reported, quiet)
    }

    @Test func aReportingWorkspaceDrawsItsStatusUnderTheNameByDefault() {
        let (_, reported, quiet) = layout()
        let metrics = SidebarLayoutMetrics.standard
        // Nothing reported: the minimal one-line row.
        #expect(quiet.height == metrics.rowHeight)
        #expect(quiet.content?.detail == nil)
        // Two entries, the log line, then the bar and its label, each on its own line.
        #expect(reported.height > metrics.rowHeightWithSubtitle)
        // The block carries the entries; the second line does not repeat them.
        #expect(reported.content?.detail == nil)
    }

    @Test func turningTheElementsOffHidesTheBlock() {
        let (_, reported, _) = layout(["agentStatus": .bool(false), "log": .bool(false), "progress": .bool(false)])
        #expect(reported.height == SidebarLayoutMetrics.standard.rowHeight)
        #expect(reported.content?.detail == nil)
    }
}
