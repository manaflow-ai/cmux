import AppKit
import CmuxNextBridge
@testable import CmuxNextDaemon
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import Testing

/// cg-design-judge's sidebar Thunderdome (Tact #115, 2026-10-14): a reported status was invisible.
/// "Tests failed", "Needs input", "Done" and "Building" were one grey subtitle, and `cmux status set
/// --state busy` drew no glyph. A one-line status also doubled the row (24 to 40 pt), so the list's
/// pitch jumped with state. Now a status's state reaches the row's badge (failed and waiting in
/// color, busy a quiet spinner), and, with the Agent Status element on (off by default since
/// 2026-10-21), a one-line status sits dim on the right of the name's line, so the row keeps its
/// height. A richer block (several entries, a log line) still draws under the name.
@MainActor @Suite(.serialized) struct SidebarStatusVisibleTests {
    /// The mapped sidebar of one workspace per name, reporting `entries` (`cmux status set`) or the
    /// hooks' status line (`statusLine`).
    static func sections(_ entries: [String: [WorkspaceStatus.Entry]] = [:],
                         statusLine: [String: String] = [:]) -> [CmuxNextSidebar.SidebarSection] {
        let names = Set(entries.keys).union(statusLine.keys).sorted()
        let store = DaemonStore()
        store.apply(snapshot: DaemonTree(workspaces: names.enumerated().map { index, name in
            WorkspaceSnapshot(id: WorkspaceHandle(rawValue: UInt64(index + 1)), key: nil, resourceID: ResourceID(rawValue: "ws-\(name)"), name: name)
        }))
        var mirror = SessionStateMirror()
        for (name, list) in entries {
            let id = ResourceID(rawValue: "ws-\(name)")
            mirror.workspaceStatus[id] = WorkspaceStatus(workspaceID: id, entries: list)
        }
        store.session.apply(.snapshot(mirror), in: store)
        let lines = Dictionary(uniqueKeysWithValues: store.workspaces.map { ($0.id, $0.name) })
        return SidebarMapping.shared.sections(store.sidebarSections,
                                              machine: SidebarMachine(id: .local, name: "This Mac", kind: .local),
                                              statusLine: { id in lines[id].flatMap { statusLine[$0] } })
    }

    /// `words`: the Agent Status element on (`sidebar.workspaceRow.agentStatus`, off by default
    /// since Lawrence 2026-10-21, "sidebar must be kept minimal by default").
    static func sidebar(_ sections: [CmuxNextSidebar.SidebarSection], detailed: Bool = false, words: Bool = false) -> SidebarView {
        let model = SidebarModel(sections: sections)
        model.rowBadgeStyle = .corner
        model.detailedStatus = detailed
        let design = DesignSettings()
        design.sidebarSections.detailedStatusIcons = detailed
        if words { design.sidebarSections.workspaceRow.base.shown.insert(.agentStatus) }
        let sidebar = SidebarView(model: model, design: design)
        sidebar.frame = NSRect(x: 0, y: 0, width: 260, height: 600)
        sidebar.renderNow() // the design's row elements reach the model
        sidebar.layoutSubtreeIfNeeded()
        sidebar.list.reload(animated: false)
        sidebar.list.rowViews.values.forEach { $0.layoutSubtreeIfNeeded() }
        return sidebar
    }

    static func row(_ sidebar: SidebarView, _ title: String) throws -> WorkspaceRowView {
        let id = try #require(sidebar.list.model.sections.flatMap(\.workspaces).first { $0.title == title }?.id)
        return try #require(sidebar.list.rowViews[.workspace(id)] as? WorkspaceRowView)
    }

    @Test func aStatusSetBusyDrawsAQuietSpinner() throws {
        let sidebar = Self.sidebar(Self.sections(["build": [WorkspaceStatus.Entry(key: "build", text: "Building", state: "busy")]]))
        let row = try Self.row(sidebar, "build")
        #expect(row.rowBadge.states == [.busy(progress: nil)], "`cmux status set --state busy` draws a glyph")
    }

    /// By default a failure is red and a question is needs you, one plain dot (Lawrence msg 11983);
    /// detailed status icons keep what the wait is for.
    @Test func aFailureAndAQuestionDrawTheirColoredGlyphs() throws {
        let sections = Self.sections([
            "tests": [WorkspaceStatus.Entry(key: "tests", text: "Tests failed", state: "error")],
            "deploy": [WorkspaceStatus.Entry(key: "deploy", text: "Needs input", state: "waiting")],
        ])
        let simple = Self.sidebar(sections)
        #expect(try Self.row(simple, "tests").rowBadge.states == [.error])
        #expect(try Self.row(simple, "deploy").rowBadge.states == [.waiting])
        let sidebar = Self.sidebar(sections, detailed: true)
        #expect(try Self.row(sidebar, "tests").rowBadge.states == [.error])
        #expect(try Self.row(sidebar, "deploy").rowBadge.states.first.map { if case .waiting = $0 { true } else { false } } == true)
    }

    @Test(arguments: ["entry", "hook line"])
    func aOneLineStatusKeepsTheRowOneLineWithItsTextOnTheRight(_ source: String) throws {
        let sections: [CmuxNextSidebar.SidebarSection] = source == "entry"
            ? Self.sections(["build": [WorkspaceStatus.Entry(key: "build", text: "Building")]])
            : Self.sections(statusLine: ["build": "Building"])
        var options = SidebarLayoutOptions()
        options.workspaceRow.base.shown.insert(.agentStatus)
        let layout = SidebarLayout.make(sections: sections, metrics: .standard, options: options)
        let id = try #require(sections.flatMap(\.workspaces).first?.id)
        #expect(layout.row(for: .workspace(id))?.height == SidebarLayoutMetrics.standard.rowHeight, "the pitch stays 24 pt")
        let row = try Self.row(Self.sidebar(sections, words: true), "build")
        #expect(row.statusBlock.isHidden)
        #expect(!row.hasSubtitle)
        #expect(!row.timeLabel.isHidden && row.timeLabel.stringValue == "Building", "the status reads on the name's line")
        #expect(row.timeLabel.frame.minX > row.title.frame.minX)
    }

    @Test func aLongStatusLeavesTheNameMostOfTheRow() throws {
        let long = "Running the full integration suite on the release candidate"
        let row = try Self.row(Self.sidebar(Self.sections(["build": [WorkspaceStatus.Entry(key: "build", text: long)]]), words: true), "build")
        #expect(!row.timeLabel.isHidden)
        #expect(row.timeLabel.frame.width <= row.bounds.width * 0.4 + 1, "the status truncates instead of the name")
        #expect(row.title.frame.width >= row.bounds.width * 0.4)
    }

    /// By default a status draws no words, only its state: the row stays its name and one mark.
    @Test func byDefaultAStatusDrawsItsStateButNoWords() throws {
        let row = try Self.row(Self.sidebar(Self.sections(["build": [WorkspaceStatus.Entry(key: "build", text: "Building", state: "busy")]])), "build")
        #expect(row.rowBadge.states == [.busy(progress: nil)])
        #expect(row.timeLabel.isHidden || row.timeLabel.stringValue.isEmpty, "words: \(row.timeLabel.stringValue)")
        #expect(row.statusBlock.isHidden && !row.hasSubtitle)
    }
}
