import AppKit
import CmuxNextBridge
import CmuxNextBridgeUI
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

    @Test func reportedEntriesUseTintedOneLinePillsAndKeepTheVisibleCap() {
        let status = SidebarWorkspaceStatus(entries: [
            .init(key: "approval", text: "Awaiting approval", tint: .palette(.green), state: "waiting"),
            .init(key: "tests", text: "Tests failed", tint: .palette(.red), state: "error"),
            .init(key: "build", text: "Building", tint: .palette(.orange), state: "busy"),
            .init(key: "extra", text: "Hidden", state: "success")
        ])
        let view = WorkspaceStatusView(frame: NSRect(x: 0, y: 0, width: 240, height: 200))
        view.configure(status, reservesBar: false)
        view.layoutSubtreeIfNeeded()
        view.updateLayer()
        view.layoutSubtreeIfNeeded()

        let labels = view.subviews.compactMap { $0 as? NSTextField }
        let pills = view.subviews.filter { type(of: $0) == NSView.self }
        #expect(labels.count == 4) // three entries plus the folded "1 more" line
        #expect(pills.count == 4)
        #expect(labels[0].stringValue == "Awaiting approval")
        #expect(labels[1].stringValue == "Tests failed")
        #expect(labels[0].maximumNumberOfLines == 1)
        #expect(labels[1].maximumNumberOfLines == 1)
        #expect(pills[0].layer?.cornerRadius ?? 0 > 0)
        #expect(pills[0].layer?.backgroundColor != nil)
        #expect(pills[1].layer?.backgroundColor != nil)
        #expect(pills[2].isHidden)
        #expect(labels[0].frame.width < view.bounds.width)
        // The pill label is wide enough for its text, so nothing truncates.
        #expect(labels[0].frame.width >= ceil(labels[0].cell?.cellSize.width ?? 0))
        // A pill keeps the plain status line height, so rows do not grow.
        #expect(labels[0].frame.height == labels[2].frame.height)
    }
}
