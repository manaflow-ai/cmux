import Testing
@testable import CmuxNextSidebar

/// The status block a workspace row draws (`cmux workspace
/// status|progress|log`): which lines, in which order, and how tall.
struct WorkspaceStatusTests {
    private func entries(_ count: Int) -> [SidebarWorkspaceStatus.Entry] {
        (0..<count).map { .init(key: "k\($0)", text: "entry \($0)") }
    }

    @Test func linesAreEntriesThenLogThenProgressLabel() {
        let status = SidebarWorkspaceStatus(
            entries: entries(2),
            progress: .init(value: 0.25, label: "Indexing"),
            log: .init(level: .error, text: "build failed")
        )
        #expect(status.lines == [
            .entry(.init(key: "k0", text: "entry 0")),
            .entry(.init(key: "k1", text: "entry 1")),
            .log(.init(level: .error, text: "build failed")),
            .progressLabel("Indexing"),
        ])
        #expect(status.showsProgressBar)
    }

    @Test func entriesPastTheLimitFoldIntoOneMoreLine() {
        let status = SidebarWorkspaceStatus(entries: entries(5))
        let lines = status.lines
        #expect(lines.count == SidebarWorkspaceStatus.visibleEntryLimit + 1)
        #expect(lines.last == .more(2))
        // Search and accessibility still see every entry.
        #expect(status.searchText.contains("entry 4"))
    }

    @Test func progressWithoutLabelIsABarOnly() {
        let status = SidebarWorkspaceStatus(progress: .init(value: nil, label: "  "))
        #expect(status.lines.isEmpty)
        #expect(status.showsProgressBar)
        #expect(!status.isEmpty)
    }

    @Test func progressValueIsClamped() {
        #expect(SidebarWorkspaceStatus.Progress(value: 1.7).value == 1)
        #expect(SidebarWorkspaceStatus.Progress(value: -1).value == 0)
        #expect(SidebarWorkspaceStatus.Progress(value: nil).value == nil)
    }

    @Test func blankEntryTextShowsTheKey() {
        #expect(SidebarWorkspaceStatus.Entry(key: "deploy", text: " \n").displayText == "deploy")
        #expect(SidebarWorkspaceStatus.Entry(key: "deploy", text: " ok ").displayText == "ok")
    }

    @Test func tintParsesPaletteTokensAndHex() {
        #expect(SidebarWorkspaceStatus.Tint("green") == .palette(.green))
        #expect(SidebarWorkspaceStatus.Tint("gray") == .palette(.grey))
        #expect(SidebarWorkspaceStatus.Tint("#336699") == .rgba(0x3366_99FF))
        #expect(SidebarWorkspaceStatus.Tint("#33669980") == .rgba(0x3366_9980))
        #expect(SidebarWorkspaceStatus.Tint("teal-ish") == nil)
        #expect(SidebarWorkspaceStatus.Tint("#12345") == nil)
        #expect(SidebarWorkspaceStatus.Tint("facade") == nil)
        #expect(SidebarWorkspaceStatus.Tint(nil) == nil)
    }

    @Test func rowHeightGrowsOneLinePerStatusLinePlusTheBar() {
        let m = SidebarLayoutMetrics.standard
        func row(_ status: SidebarWorkspaceStatus) -> SidebarWorkspace {
            SidebarWorkspace(id: SidebarWorkspaceID("w"), title: "w", status: status)
        }
        let full = SidebarWorkspaceStatus(entries: entries(4), progress: .init(value: 0.5, label: "Half"),
                                          log: .init(level: .info, text: "hi"))
        // 3 entries + "1 more" + log + progress label, and the bar.
        #expect(m.height(for: row(full)) == m.rowHeight + 6 * m.statusLineHeight + m.progressBarHeight)
        let barOnly = SidebarWorkspaceStatus(progress: .init(value: 0.1))
        #expect(m.height(for: row(barOnly)) == m.rowHeight + m.progressBarHeight)
        #expect(WorkspaceStatusView.height(of: full) == m.height(for: row(full)) - m.rowHeight)
    }

    @Test func aTallCustomRowHeightKeepsStatusLinesApart() {
        var m = SidebarLayoutMetrics.standard
        m.minimumStatusLineHeight = 12
        m.rowHeight = m.rowHeightWithSubtitle + 4
        #expect(m.statusLineHeight == 12)
        let row = SidebarWorkspace(id: SidebarWorkspaceID("w"), title: "w", status: SidebarWorkspaceStatus(entries: entries(2)))
        #expect(m.height(for: row) == m.rowHeight + 24)
    }

    @Test func layoutStacksTallStatusRows() {
        let m = SidebarLayoutMetrics.standard
        let tall = SidebarWorkspace(id: SidebarWorkspaceID("a"), title: "a",
                                    status: SidebarWorkspaceStatus(entries: entries(2)))
        let short = SidebarWorkspace(id: SidebarWorkspaceID("b"), title: "b")
        let sections = [SidebarSection(kind: .machine(SidebarMachine(id: .local, name: "Mac", kind: .local)),
                                       nodes: [.workspace(tall), .workspace(short)])]
        let rows = SidebarLayout.make(sections: sections, metrics: m).rows.filter {
            if case .workspace = $0.key { true } else { false }
        }
        #expect(rows.count == 2)
        #expect(rows[0].height == m.rowHeight + 2 * m.statusLineHeight)
        #expect(rows[1].y == rows[0].maxY + m.rowSpacing)
    }

    @Test func filterMatchesStatusText() {
        let ws = SidebarWorkspace(id: SidebarWorkspaceID("a"), title: "api",
                                  status: SidebarWorkspaceStatus(entries: [.init(key: "ci", text: "deploying staging")]))
        #expect(ws.status?.searchText == "deploying staging")
    }
}
