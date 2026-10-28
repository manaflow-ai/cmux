import AppKit
import CmuxNextDesign
import CmuxNextLaunch
@testable import CmuxNextSidebar
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import Testing

/// With 60 workspaces, the sidebar builds row views only for the rows its clip shows
/// (at most `LaunchRows.Report.slack` more) until startup completes, and its overscan rows in the
/// afterStartup task. Prints one `SIDEBAR-LAUNCH-ROWS` line with the counts, held and not held.
@MainActor @Suite(.serialized)
struct SidebarLaunchRowsTests {
    @Test func aLaunchBuildsOnlyTheVisibleRowsUntilStartupCompletes() throws {
        let scheduler = StartupTestScheduler()
        let held = LaunchRowsFixture(count: 60)
        defer { held.close() }
        var reports: [SidebarModel.LaunchRows.Report] = []
        held.sidebar.followLaunch(scheduler.startup) { reports.append($0) }
        held.show()
        #expect(held.list.launchRows.holdsOffscreenRows)
        #expect(held.sidebar.launchRowsReport == nil, "no report before completion")

        scheduler.complete()
        let report = try #require(held.sidebar.launchRowsReport)
        #expect(reports == [report], "told once, at completion")
        #expect(report.visible == held.visibleRows && report.visible > 0)
        #expect(report.isWithinVisibleRows, "built \(report.built) row views for \(report.visible) visible rows")
        #expect(held.list.launchRows.holdsOffscreenRows, "the overscan rows wait for the afterStartup task")

        // The same sidebar with no launch to follow (a window made after startup): the overscan rows come at once.
        let unheld = LaunchRowsFixture(count: 60)
        defer { unheld.close() }
        unheld.sidebar.followLaunch(nil) { _ in Issue.record("no launch, no report") }
        unheld.show()
        let eager = unheld.list.launchRowsReport()
        print("SIDEBAR-LAUNCH-ROWS n=60 visible=\(report.visible) held=\(report.built) unheld=\(eager.built)")
        #expect(eager.built > report.built, "without the hold the list builds its overscan rows too")

        scheduler.fire()
        #expect(!held.list.launchRows.holdsOffscreenRows, "the afterStartup task released the hold")
        #expect(held.list.rowPool.made > report.built, "the afterStartup task built the overscan rows")
        #expect(held.list.rowPool.made <= eager.built, "and no more than a window made after startup holds")
        scheduler.fire()
        #expect(reports.count == 1)
    }

    /// The counts reach `debug.startup`'s counter values (`AppServices.launchValues`) at completion, and the
    /// bench's pipe once each; a second window's are dropped.
    @Test func theLaunchCountsAreStartupCounterValuesAfterCompletion() throws {
        let scheduler = StartupTestScheduler()
        let fixture = LaunchRowsFixture(count: 60)
        defer { fixture.close() }
        var piped: [String] = []
        let counters = LaunchValueMarks { piped.append("\($0) \($1)") }
        fixture.sidebar.followLaunch(scheduler.startup) { counters.recordSidebarLaunchRows(built: $0.built, visible: $0.visible) }
        fixture.show()
        #expect(counters.values.isEmpty, "no counts before completion")

        scheduler.complete()
        let report = try #require(fixture.sidebar.launchRowsReport)
        #expect(counters.values == [LaunchValueMarks.sidebarRowsBuilt: Double(report.built),
                                    LaunchValueMarks.sidebarRowsVisible: Double(report.visible)])
        let expectedPipe = ["\(LaunchValueMarks.sidebarRowsBuilt) \(report.built)", "\(LaunchValueMarks.sidebarRowsVisible) \(report.visible)"]
        #expect(piped == expectedPipe)

        counters.recordSidebarLaunchRows(built: report.built + 40, visible: 1)
        #expect(counters.values[LaunchValueMarks.sidebarRowsBuilt] == Double(report.built), "the first window's counts stay")
        #expect(piped == expectedPipe, "a second window sends nothing")
    }

    @Test func aWindowMadeAfterStartupCompletedHoldsNothing() {
        let scheduler = StartupTestScheduler()
        scheduler.complete()
        let fixture = LaunchRowsFixture(count: 60)
        defer { fixture.close() }
        fixture.sidebar.followLaunch(scheduler.startup) { _ in Issue.record("startup already completed") }
        #expect(!fixture.list.launchRows.holdsOffscreenRows)
        fixture.show()
        scheduler.fire()
        #expect(fixture.sidebar.launchRowsReport == nil)
    }
}

/// A sidebar over `count` workspaces with a status line (two-line rows), a third of them in groups of
/// eight, in a borderless window `height` tall that it shows only on ``show()``: a test follows the launch
/// first, as the App does right after making the sidebar.
@MainActor
private final class LaunchRowsFixture {
    let sidebar: SidebarView
    let window: NSWindow
    private let height: CGFloat
    var list: SidebarListView { sidebar.list }

    init(count: Int, height: CGFloat = 900) {
        _ = NSApplication.shared
        self.height = height
        let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
        func workspace(_ index: Int) -> SidebarWorkspace {
            SidebarWorkspace(id: WorkspaceID("launch-\(index)"), title: "Workspace \(index)",
                             directory: "~/fun/feature-\(index)", status: "Running step \(index)")
        }
        let grouped = count / 3
        var nodes: [SidebarNode] = stride(from: 0, to: grouped, by: 8).enumerated().map { group, start in
            .group(SidebarGroup(id: GroupID("launch-g\(group)"), name: "Group \(group)", color: .green,
                                workspaces: (start..<min(grouped, start + 8)).map(workspace)))
        }
        nodes += (grouped..<count).map { .workspace(workspace($0)) }
        let model = SidebarModel(sections: [SidebarSection(kind: .machine(machine), nodes: nodes)],
                                 activeWorkspaceID: WorkspaceID("launch-0"))
        sidebar = SidebarView(model: model, design: DesignSettings())
        window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 260, height: height), styleMask: [.borderless],
                          backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
    }

    /// Puts the sidebar in the window, lays it out and draws one frame.
    func show() {
        window.contentView = sidebar
        sidebar.frame = NSRect(x: 0, y: 0, width: 260, height: height)
        window.orderFrontRegardless()
        sidebar.renderNow()
        // sync-layout: the test reads the rows the first frame realizes
        window.contentView?.layoutSubtreeIfNeeded()
        // sync-layout: one display frame, as the launch's first frame draws
        window.displayIfNeeded()
    }

    func close() { window.close() }

    /// Rows the visible clip shows now.
    var visibleRows: Int {
        let visible = sidebar.scrollView.contentView.bounds
        return list.displayed.rows.filter { visible.intersects(list.frame(for: $0)) }.count
    }
}
