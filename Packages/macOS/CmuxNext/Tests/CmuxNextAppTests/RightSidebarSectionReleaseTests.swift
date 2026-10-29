import AppKit
import CmuxHomeCore
@testable import CmuxNextApp
import CmuxNextCompat
import CmuxNextDesign
import CmuxNextFilesUI
import CmuxNextHibernation
import CmuxNextMemory
@testable import CmuxNextHome
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import Foundation
import Testing

/// Right sidebar sections and docked Home views are released when hidden (`ContentKind.sidebarSection`, feature
/// `memoryDiscardSidebarSections`): a section hidden 10 min, or hidden at critical memory pressure,
/// lets its view go on the planner's one-shot deadline after its owner saved a view-state record; the next show
/// makes it again from that record. The shown section never goes. Time and pressure are the test's own.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct RightSidebarSectionReleaseTests {
    /// The app's sidebar section planner on a manual clock and a hand-driven memory level.
    @MainActor private final class Planner {
        let clock = ManualClock()
        let memory = ManualMemoryLevelRegistry()
        let discards: SidebarSectionDiscards
        var scheduler: ContentDiscardScheduler { discards.scheduler }

        init(level: MemoryPressureLevel = .normal) {
            memory.send(level)
            discards = SidebarSectionDiscards(scheduler: ContentDiscardScheduler(kind: .sidebarSection, memory: memory, clock: clock))
        }

        /// `seconds` pass; the planner looks, as its deadline would, and the releases it starts end.
        func pass(_ seconds: Int64) async {
            clock.advance(by: .seconds(seconds))
            scheduler.replan()
            await scheduler.settled()
        }
    }

    /// A section with its own state, as Files and Find keep theirs.
    @MainActor private final class KeepingSection: NSView, SidebarSectionStateKeeping {
        var sectionState = SidebarSectionState()
        var holdsUnsavedInput = false
        private(set) var restored: [SidebarSectionState] = []
        func restoreSectionState(_ state: SidebarSectionState) {
            restored.append(state)
            sectionState = state
        }
    }

    /// A section without its own state: a tall list in a scroll view.
    private static func plainSection() -> NSView {
        let section = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 300))
        let scroll = NSScrollView(frame: section.bounds)
        scroll.autoresizingMask = [.width, .height]
        scroll.documentView = FlippedDocument(frame: NSRect(x: 0, y: 0, width: 240, height: 3_000))
        section.addSubview(scroll)
        return section
    }

    private final class FlippedDocument: NSView {
        override var isFlipped: Bool { true }
    }

    /// A section without its own state whose field holds a name the person typed and did not commit.
    private static func typedSection() -> NSView {
        let section = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 300))
        section.addSubview(NSTextField(string: "half a name"))
        return section
    }

    /// Polls `condition` on the real clock for a few seconds: the sections list and render on their own tasks.
    private static func eventually(_ condition: () -> Bool) async -> Bool {
        await HomeChiefHostedSettingsTests.eventually(.seconds(5), condition)
    }

    /// `git` outside a repository: no git states.
    private struct NoGit: MarkdownGitRunning {
        func run(_ arguments: [String], in folder: String) async -> MarkdownGitOutput? { MarkdownGitOutput(status: 128, output: "") }
    }

    /// root/{Alpha/a00..a29.txt, Beta/b00..b29.txt, f00..f29.txt}: a tree taller than the panel once both folders open.
    private static func tallFolder() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("section-release-\(UUID().uuidString)", isDirectory: true)
        for (folder, prefix) in [("Alpha", "a"), ("Beta", "b"), ("", "f")] {
            let directory = folder.isEmpty ? root : root.appendingPathComponent(folder, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for index in 0..<30 {
                try Data("x".utf8).write(to: directory.appendingPathComponent("\(prefix)\(index < 10 ? "0" : "")\(index).txt"))
            }
        }
        return root.standardizedFileURL
    }

    private static func scrollView(in view: NSView) -> NSScrollView? {
        view.subviews.lazy.compactMap { $0 as? NSScrollView }.first
    }

    /// A panel over `planner` whose sections `make` builds; `made` counts each mode's views.
    private final class Panel {
        var made: [RightSidebarMode: Int] = [:]
        var view: RightSidebarView!
    }

    private static func panel(_ planner: Planner?, make: @escaping @MainActor (RightSidebarMode) -> NSView) -> Panel {
        let panel = Panel()
        panel.view = RightSidebarView(modes: [.files, .find, .sessions], title: { $0.rawValue }, icon: { _ in nil },
                                      makeSection: { [weak panel] mode in
                                          panel?.made[mode, default: 0] += 1
                                          return make(mode)
                                      }, run: { _ in }, planner: planner?.discards)
        panel.view.frame = NSRect(x: 0, y: 0, width: 240, height: 600)
        return panel
    }

    // MARK: The right sidebar

    @Test func aSectionSwitchedAwayFromGoesTenMinutesLaterOnOneDeadline() async {
        let planner = Planner()
        let panel = Self.panel(planner) { _ in NSView() }
        panel.view.show(.files)
        weak var files = panel.view.sectionView(.files)
        #expect(files != nil)
        #expect(!planner.scheduler.hasDeadline, "a release was armed while the only section shows")

        panel.view.show(.find)
        #expect(planner.scheduler.nextCheck == 600, "no one-shot deadline 10 min after the switch: \(planner.scheduler.nextCheck ?? -1)")
        await planner.pass(599)
        #expect(panel.view.sectionView(.files) != nil, "the section went before 10 min hidden")

        await planner.pass(2)
        #expect(panel.view.sectionView(.files) == nil)
        #expect(files == nil, "the released section's view is still alive")
        #expect(planner.scheduler.discardedCount == 1)
        #expect(panel.view.sectionView(.find) != nil, "the shown section went")
        #expect(!planner.scheduler.hasDeadline, "a deadline stayed armed with nothing hidden")
    }

    @Test func switchingBackMakesTheSectionAgainWithItsScrollExpandedRowsAndQuery() async {
        let planner = Planner()
        let panel = Self.panel(planner) { _ in KeepingSection() }
        let state = SidebarSectionState(scroll: CGPoint(x: 0, y: 240), query: "needle", selection: "/repo/Sources/App.swift",
                                        expanded: ["/repo/Sources", "/repo/Tests"])
        panel.view.show(.files)
        let first = panel.view.sectionView(.files) as? KeepingSection
        first?.sectionState = state

        panel.view.show(.find)
        await planner.pass(601)
        #expect(panel.view.sectionView(.files) == nil)

        panel.view.show(.files)
        let again = panel.view.sectionView(.files) as? KeepingSection
        #expect(panel.made[.files] == 2, "the switch back did not make the section again")
        #expect(again !== first)
        #expect(again?.restored == [state], "the section came back without its record: \(again?.restored ?? [])")
        #expect(panel.view.shownMode == .files && again?.isHidden == false)
    }

    @Test func aSectionWithoutItsOwnStateComesBackAtItsScroll() async throws {
        let planner = Planner()
        let panel = Self.panel(planner) { _ in Self.plainSection() }
        panel.view.show(.files)
        let first = try #require(panel.view.sectionView(.files).flatMap(Self.scrollView))
        first.contentView.scroll(to: CGPoint(x: 0, y: 900))

        panel.view.show(.find)
        await planner.pass(601)
        panel.view.show(.files)
        // sync-layout: the test reads the scroll the next frame's layout puts back.
        panel.view.layoutSubtreeIfNeeded()
        let again = try #require(panel.view.sectionView(.files).flatMap(Self.scrollView))
        #expect(again !== first)
        #expect(again.documentVisibleRect.origin.y == 900, "the section came back at \(again.documentVisibleRect.origin.y)")
    }

    @Test func theShownSectionNeverGoesAndAHiddenOneGoesSoonAtCriticalPressure() async {
        let planner = Planner(level: .critical)
        let panel = Self.panel(planner) { _ in NSView() }
        panel.view.show(.files)
        await planner.pass(3_600)
        #expect(panel.view.sectionView(.files) != nil, "critical pressure released the shown section")

        panel.view.show(.find)
        #expect(planner.scheduler.nextCheck == 10, "the urgent pace's 10 s hidden")
        await planner.pass(11)
        #expect(panel.view.sectionView(.files) == nil, "a hidden section was kept at critical pressure")
        #expect(panel.view.sectionView(.find) != nil)
    }

    @Test func aSectionShownBeforeItsDeadlineStaysAndCountsAgainFromItsNextHide() async {
        let planner = Planner()
        let panel = Self.panel(planner) { _ in NSView() }
        panel.view.show(.files)
        panel.view.show(.find)
        await planner.pass(300)
        panel.view.show(.files)
        panel.view.show(.find)
        await planner.pass(500)
        #expect(panel.view.sectionView(.files) != nil, "the hidden time counted from the first switch, not the last")
        await planner.pass(101)
        #expect(panel.view.sectionView(.files) == nil)
        #expect(panel.made[.files] == 1)
    }

    @Test func withoutThePlannerEverySectionIsKept() async {
        let panel = Self.panel(nil) { _ in NSView() }
        panel.view.show(.files)
        panel.view.show(.find)
        panel.view.show(.files)
        #expect(panel.made == [.files: 1, .find: 1])
        #expect(panel.view.sectionView(.find) != nil)
    }

    @Test func aSectionHoldingUnsavedInputStaysHiddenAtAnyPressure() async {
        let planner = Planner()
        let panel = Self.panel(planner) { mode in
            switch mode {
            case .files: return KeepingSection()
            case .sessions: return Self.typedSection()
            default: return NSView()
            }
        }
        panel.view.show(.files)
        let files = panel.view.sectionView(.files) as? KeepingSection
        files?.holdsUnsavedInput = true // a row's name being typed
        panel.view.show(.sessions)
        panel.view.show(.find)
        await planner.pass(601)
        #expect(panel.view.sectionView(.files) != nil, "a hidden section with a name being typed went after 10 min")
        #expect(panel.view.sectionView(.sessions) != nil, "a hidden section with typed text its record does not keep went")
        #expect(planner.scheduler.exemptions.values.filter { $0 == .formInput }.count == 2, "\(planner.scheduler.exemptions)")

        planner.memory.send(.critical)
        await planner.pass(3_600)
        #expect(panel.view.sectionView(.files) != nil && panel.view.sectionView(.sessions) != nil,
                "critical pressure let a hidden section with unsaved input go")

        files?.holdsUnsavedInput = false
        await planner.pass(601)
        #expect(panel.view.sectionView(.files) == nil, "the section stayed after its input was committed")
        #expect(panel.view.sectionView(.sessions) != nil)
    }

    @Test func theShownSectionGoesTenMinutesAfterThePanelCollapsesAndComesBackOnShow() async {
        let planner = Planner()
        let panel = Self.panel(planner) { _ in NSView() }
        panel.view.show(.files)
        weak var files = panel.view.sectionView(.files)
        #expect(!planner.scheduler.hasDeadline)

        panel.view.panelDidHide()
        #expect(planner.scheduler.nextCheck == 600, "the collapsed panel's section armed no deadline: \(planner.scheduler.nextCheck ?? -1)")
        await planner.pass(601)
        #expect(panel.view.sectionView(.files) == nil && files == nil, "the collapsed panel kept its section alive")

        panel.view.show(.files)
        #expect(panel.made[.files] == 2, "showing the panel again did not make its section again")
        #expect(panel.view.shownSection != nil && panel.view.shownMode == .files)
    }

    @Test func theFilesTreeComesBackWithItsOpenFoldersSelectionAndScroll() async throws {
        let root = try Self.tallFolder()
        let shown = VisibilityNode(root: "test.rightSidebar.files", own: .visible)
        let planner = Planner()
        let panel = Self.panel(planner) { mode in
            guard mode == .files else { return NSView() }
            let section = FileExplorerSectionView(model: FileExplorerModel(git: NoGit(), watcher: FileExplorerWatchTests.ManualWatch()),
                                                  mainWork: MainWorkScheduler(budget: MainFrameBudget()), rootFolder: { root },
                                                  perform: { _ in }, rowMenu: { _ in nil })
            try? section.visibilityNode.attach(to: shown)
            return section
        }
        panel.view.show(.files)
        let first = try #require(panel.view.sectionView(.files) as? FileExplorerSectionView)
        let listed = await Self.eventually { first.model.rows.count == 32 }
        try #require(listed, "the tree never listed its root: \(first.model.rows.map(\.name))")
        let alpha = try #require(first.model.rows.first { $0.name == "Alpha" }?.url)
        let beta = try #require(first.model.rows.first { $0.name == "Beta" }?.url)
        await first.model.toggle(alpha)
        await first.model.toggle(beta)
        let picked = try #require(first.model.rows.first { $0.name == "b05.txt" }?.url)
        first.model.selection = picked
        let rendered = await Self.eventually { first.table.numberOfRows == 92 }
        try #require(rendered, "the open tree never rendered")
        // sync-layout: the test scrolls the laid-out tree, as the person does.
        panel.view.layoutSubtreeIfNeeded()
        first.table.enclosingScrollView?.contentView.scroll(to: CGPoint(x: 0, y: 300))
        let scrolled = first.treeScroll
        try #require(scrolled.y > 0, "the tree is too short to scroll")

        panel.view.show(.find)
        await planner.pass(601)
        #expect(panel.view.sectionView(.files) == nil, "the hidden Files section stayed")

        panel.view.show(.files)
        let again = try #require(panel.view.sectionView(.files) as? FileExplorerSectionView)
        #expect(again !== first)
        let reopened = await Self.eventually { again.model.expandedFolders == [alpha, beta] && again.model.selection == picked }
        #expect(reopened, "the tree came back with \(again.model.expandedFolders) open and \(String(describing: again.model.selection)) selected")
        let back = await Self.eventually { again.table.numberOfRows == 92 && abs(again.treeScroll.y - scrolled.y) < 1 }
        #expect(back, "the tree came back at \(again.treeScroll.y), not \(scrolled.y)")
        #expect(again.table.selectedRow == again.model.rows.firstIndex { $0.url == picked })
    }

    @Test func theFindSectionComesBackWithItsQueryResultAndScroll() async throws {
        let matches = (0..<80).map {
            RipgrepMatch(path: "/tmp/project/F\($0).swift", relativePath: "F\($0).swift", line: $0 + 1, column: 1, preview: "needle \($0)")
        }
        let shown = VisibilityNode(root: "test.rightSidebar.find", own: .visible)
        let planner = Planner()
        let panel = Self.panel(planner) { mode in
            guard mode == .find else { return NSView() }
            let section = FindSectionView(model: FindSectionModel { _, _ in .matches(matches, limited: false) },
                                          mainWork: MainWorkScheduler(budget: MainFrameBudget()),
                                          rootFolder: { URL(fileURLWithPath: "/tmp/project", isDirectory: true) },
                                          effects: NullFileExplorerEffects())
            try? section.visibilityNode.attach(to: shown)
            return section
        }
        panel.view.show(.find)
        let first = try #require(panel.view.sectionView(.find) as? FindSectionView)
        first.field.stringValue = "needle"
        await first.model.search("needle")
        let listed = await Self.eventually { first.table.numberOfRows == matches.count }
        try #require(listed, "the results never rendered")
        // sync-layout: the test scrolls the laid-out results, as the person does.
        panel.view.layoutSubtreeIfNeeded()
        first.table.selectRowIndexes(IndexSet(integer: 40), byExtendingSelection: false)
        first.table.enclosingScrollView?.contentView.scroll(to: CGPoint(x: 0, y: 900))
        let scrolled = first.resultsScroll
        try #require(scrolled.y > 0, "the results are too short to scroll")
        let cursor = FindSectionView.cursor(of: matches[40])
        #expect(first.cursor == cursor)

        panel.view.show(.files)
        await planner.pass(601)
        #expect(panel.view.sectionView(.find) == nil, "the hidden Find section stayed")

        panel.view.show(.find)
        let again = try #require(panel.view.sectionView(.find) as? FindSectionView)
        #expect(again !== first)
        #expect(again.field.stringValue == "needle", "the Find section came back without its query")
        let back = await Self.eventually { again.cursor == cursor && abs(again.resultsScroll.y - scrolled.y) < 1 }
        #expect(back, "Find came back on \(again.cursor ?? "nothing") at \(again.resultsScroll.y), not \(cursor) at \(scrolled.y)")
    }

    @Test func theAppCountsSidebarSectionDiscardsOnlyWhileTheFeatureReleasesThem() {
        #expect(MemoryHistograms.discardKinds(overlayPages: false, sidebarSections: true).contains(ContentKind.sidebarSection.rawValue))
        #expect(!MemoryHistograms.discardKinds(overlayPages: false).contains(ContentKind.sidebarSection.rawValue))
    }

    // MARK: The docked Home

    /// A dock whose views record what it asked of them.
    private final class Dock: HomeDockSwitchView {
        var made: [HomeDockMode: Int] = [:]
        var released: [HomeDockMode] = []
        var opened: [(HomeDockMode, String)] = []
        var shownSelection: [HomeDockMode: HomeDockSelection] = [:]

        override func makeContent(for mode: HomeDockMode) -> NSView? {
            made[mode, default: 0] += 1
            return NSView()
        }

        /// The views holding a draft their record does not keep.
        var unsaved: Set<HomeDockMode> = []
        var restoredRecords: [HomeDockRecord] = []
        /// The next save takes its record, then waits for ``gate`` to resume.
        var holdNextSave = false
        var gate: CheckedContinuation<Void, Never>?
        var savesEnded = 0

        override func releaseContent(for mode: HomeDockMode) { released.append(mode) }
        override func selection(in mode: HomeDockMode) async -> HomeDockSelection? { shownSelection[mode] }
        override func holdsUnsavedInput(in mode: HomeDockMode) -> Bool { unsaved.contains(mode) }

        override func saveViewState(in mode: HomeDockMode) async -> HomeDockRecord? {
            let record = await super.saveViewState(in: mode)
            if holdNextSave {
                holdNextSave = false
                await withCheckedContinuation { continuation in gate = continuation }
            }
            savesEnded += 1
            return record
        }

        override func restoreViewState(_ record: HomeDockRecord, in mode: HomeDockMode) {
            restoredRecords.append(record)
            super.restoreViewState(record, in: mode)
        }
        override func open(_ selection: HomeDockSelection, in mode: HomeDockMode) {
            opened.append((mode, selection.conversation))
            shownSelection[mode] = selection
        }
    }

    @Test func theHiddenDockViewGoesWithItsSelectionAndComesBackOnIt() async {
        let channelsWere = DesignSettings.shared.homeChannelsEnabled
        DesignSettings.shared.homeChannelsEnabled = true
        defer { DesignSettings.shared.homeChannelsEnabled = channelsWere }
        let planner = Planner()
        let dock = Dock(mode: .messages, planner: planner.discards)
        dock.shownSelection[.messages] = HomeDockSelection(conversation: "conv_release_a")
        weak var messages = dock.madeContent(.messages)

        dock.switchTo(.channels, selection: HomeDockSelection(conversation: "conv_release_b"))
        await dock.settled()
        #expect(planner.scheduler.nextCheck == 600)
        await planner.pass(601)
        #expect(dock.madeContent(.messages) == nil && messages == nil, "the hidden Messages view is still alive")
        #expect(dock.released == [.messages])
        #expect(dock.madeContent(.channels) != nil, "the shown view went")

        dock.opened = []
        dock.shownSelection[.messages] = nil
        dock.switchTo(.messages, selection: nil)
        await dock.settled()
        #expect(dock.made[.messages] == 2, "the switch back did not make Messages again")
        #expect(dock.opened.first.map { $0.0 == .messages && $0.1 == "conv_release_a" } == true,
                "Messages came back without its selection: \(dock.opened)")
        dock.close()
    }

    @Test func aHiddenDockViewWithADraftStaysPastTenMinutesAndAtCriticalPressure() async {
        let channelsWere = DesignSettings.shared.homeChannelsEnabled
        DesignSettings.shared.homeChannelsEnabled = true
        defer { DesignSettings.shared.homeChannelsEnabled = channelsWere }
        let planner = Planner()
        let dock = Dock(mode: .messages, planner: planner.discards)
        weak var messages = dock.madeContent(.messages)
        dock.unsaved = [.messages] // an unsent New Message: recipients and a body
        dock.switchTo(.channels, selection: HomeDockSelection(conversation: "conv_draft_b"))
        await dock.settled()

        await planner.pass(601)
        #expect(dock.madeContent(.messages) != nil && messages != nil, "a hidden Messages view with a draft went after 10 min")
        #expect(planner.scheduler.exemptions.values.contains(.formInput), "\(planner.scheduler.exemptions)")
        planner.memory.send(.critical)
        await planner.pass(3_600)
        #expect(dock.madeContent(.messages) != nil, "critical pressure let a hidden draft go")
        #expect(dock.released.isEmpty)

        dock.unsaved = []
        await planner.pass(601)
        #expect(dock.released == [.messages], "the view stayed after its draft was sent")
        dock.close()
    }

    /// A save the person's show interrupted keeps nothing: a later release whose save finds no selection does not
    /// bring the view back on the interrupted save's selection.
    @Test func aSaveThatAShowInterruptedLeavesNoRecordForALaterRelease() async throws {
        let channelsWere = DesignSettings.shared.homeChannelsEnabled
        DesignSettings.shared.homeChannelsEnabled = true
        defer { DesignSettings.shared.homeChannelsEnabled = channelsWere }
        let planner = Planner()
        let dock = Dock(mode: .channels, planner: planner.discards)
        let stale = HomeDockSelection(conversation: "conv_stale_s1")
        let other = HomeDockSelection(conversation: "conv_stale_m")
        dock.shownSelection[.channels] = stale
        dock.switchTo(.messages, selection: other)
        await dock.settled()

        // Channels comes due: its save takes the selection and waits.
        dock.holdNextSave = true
        planner.clock.advance(by: .seconds(601))
        planner.scheduler.replan()
        let saving = await Self.eventually { dock.gate != nil }
        try #require(saving, "the planner never saved the hidden Channels view")

        // The person shows Channels before the release commits; the save ends after the show.
        dock.switchTo(.channels, selection: stale)
        await dock.settled()
        dock.gate?.resume()
        dock.gate = nil
        let ended = await Self.eventually { dock.savesEnded == 1 }
        try #require(ended, "the interrupted save never ended")
        await planner.scheduler.settled()
        #expect(dock.madeContent(.channels) != nil, "the shown Channels view went")

        // Hidden again with nothing the page answers: it goes with no selection.
        dock.shownSelection[.channels] = nil
        dock.switchTo(.messages, selection: other)
        await dock.settled()
        await planner.pass(601)
        #expect(dock.released == [.channels])

        dock.switchTo(.channels, selection: nil)
        await dock.settled()
        #expect(dock.made[.channels] == 2, "the switch back did not make Channels again")
        #expect(dock.restoredRecords.isEmpty, "Channels came back on a save its show interrupted: \(dock.restoredRecords)")
        dock.close()
    }

    /// The real docked Messages view keeps its conversation, its list's scroll and its search in its record, and a
    /// view made again shows them (the scroll once its rows are in), as classic Home's discard does.
    @Test func theDockedMessagesRecordKeepsItsConversationListScrollAndSearch() async throws {
        let services = try await TopHomePageDiscardTests.services()
        let window = TopHomePageDiscardTests.window()
        defer { window.orderOut(nil) }
        let container = try #require(window.contentView)
        let first = HomeDockView(services: services, mode: .messages, planner: nil)
        first.frame = container.bounds
        container.addSubview(first)
        let page = try #require(first.messages)
        let filled = await Self.eventually { page.rows.count >= TopHomePageDiscardTests.conversations.count }
        try #require(filled, "the docked Messages view never listed the conversations")
        // sync-layout: the test scrolls the laid-out list, as the person does.
        first.layoutSubtreeIfNeeded()
        let chosen = ConversationID(TopHomePageDiscardTests.conversations[7])
        page.show(chosen)
        page.list.scroll(to: CGPoint(x: 0, y: 400))
        let scrolled = page.list.scrollOrigin
        try #require(scrolled.y > 0, "the list is too short to scroll")
        let record = try #require(await first.saveViewState(in: .messages))
        #expect(record.selection?.conversation == chosen.rawValue)
        #expect(record.view.scroll == scrolled)
        first.removeFromSuperview()
        first.close()

        let second = HomeDockView(services: services, mode: .messages, planner: nil)
        second.frame = container.bounds
        container.addSubview(second)
        second.restoreViewState(record, in: .messages)
        let again = try #require(second.messages)
        #expect(again !== page)
        #expect(again.shown == chosen, "the docked Messages view came back on another conversation")
        let restored = await Self.eventually { again.list.scrollOrigin == scrolled }
        #expect(restored, "the docked list came back at \(again.list.scrollOrigin), not \(scrolled)")

        again.list.setSearch("Group 1")
        let searched = try #require(await second.saveViewState(in: .messages))
        #expect(searched.view.query == "Group 1")
        let third = HomeDockView(services: services, mode: .messages, planner: nil)
        third.restoreViewState(searched, in: .messages)
        #expect(third.messages?.list.searchQuery == "Group 1", "the docked Messages view lost its search")
        second.close()
        third.close()
    }
}
