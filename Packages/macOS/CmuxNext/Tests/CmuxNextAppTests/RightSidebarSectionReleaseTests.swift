import AppKit
@testable import CmuxNextApp
import CmuxNextCompat
import CmuxNextDesign
import CmuxNextHibernation
import CmuxNextMemory
@testable import CmuxNextHome
import CmuxNextWakeupsTestSupport
import Testing

/// Right sidebar sections and docked Home views are released when hidden (`ContentKind.sidebarSection`, feature
/// `memoryDiscardSidebarSections`, p07-memory-100): a section hidden 10 min, or hidden at critical memory pressure,
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

        override func releaseContent(for mode: HomeDockMode) { released.append(mode) }
        override func selection(in mode: HomeDockMode) async -> HomeDockSelection? { shownSelection[mode] }
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
}
