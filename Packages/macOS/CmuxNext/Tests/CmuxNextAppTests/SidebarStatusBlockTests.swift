import CmuxNextBridge
@testable import CmuxNextDaemon
import CmuxNextSettings
@testable import CmuxNextSidebar
import AppKit
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
        store.session.apply(.snapshot(mirror), to: store.workspaces)

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
            .init(key: "build", text: "Building", tint: .palette(.orange)),
            .init(key: "tests", text: "412 passed", tint: .palette(.green)),
            .init(key: "deploy", text: "Deploying", tint: .palette(.purple)),
            .init(key: "extra", text: "Hidden")
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
        #expect(labels[0].stringValue == "Building")
        #expect(labels[1].stringValue == "412 passed")
        #expect(labels[0].maximumNumberOfLines == 1)
        #expect(labels[1].maximumNumberOfLines == 1)
        #expect(pills[0].layer?.cornerRadius ?? 0 > 0)
        #expect(pills[0].layer?.backgroundColor != nil)
        #expect(pills[1].layer?.backgroundColor != nil)
        #expect(labels[0].frame.width < view.bounds.width)
        #expect(labels[0].frame.height <= SidebarLayoutMetrics.standard.statusLineHeight)
    }
}
