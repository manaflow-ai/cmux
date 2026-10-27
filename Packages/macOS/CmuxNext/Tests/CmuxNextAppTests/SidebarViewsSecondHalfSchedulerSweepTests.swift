import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxNextWakeups
import Testing

/// The p06-scheduler-328 sweep of CmuxNextSidebar/Views (second half): the notice card reads its own
/// visibility node instead of walking its ancestors, and the sidebar list follows the scroll-bar setting
/// through the app's one observer, and the sidebar's draw and the rail's marks are visible observations of
/// their own nodes while the list settings reach the model on a service observation
/// (plans/cmux-next/chrome-parity/p06-scheduler.md, recipes R-obs, R-vis, R-hide, R-appear and R-notif; rule 9).
@MainActor @Suite(.serialized) struct SidebarViewsSecondHalfSchedulerSweepTests {
    static let tip = SidebarNoticeCard(id: "tip", title: "Command Palette", dismissLabel: "Close", shownAction: "tip.shown")

    /// A window whose node reads visible (it is never ordered in), holding `host`.
    private static func window(holding host: NSView) -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 400), styleMask: [.titled], backing: .buffered,
                              defer: true)
        window.isReleasedWhenClosed = false
        _ = WindowVisibilitySource.of(window, read: { _ in .visible })
        window.contentView = host
        return window
    }

    /// A notice under a collapsed sidebar is not reported shown; the sidebar opening reports it once,
    /// through the card's node (no unhide override does it any more).
    @Test func aNoticeIsReportedShownWhenItsNodeShows() {
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
        let window = Self.window(holding: host)
        defer { window.close() }
        host.isHidden = true
        let card = SidebarNoticeCardView(frame: NSRect(x: 0, y: 0, width: 240, height: SidebarNoticeCardView.height(for: Self.tip)))
        host.addSubview(card)
        var sent: [String] = []
        card.onAction = { _, action in sent.append(action) }
        card.configure(Self.tip)
        #expect(!card.loopNode.isVisible, "the card's node is visible under a hidden sidebar")
        #expect(sent.isEmpty, "a notice under a hidden sidebar was reported shown: \(sent)")
        host.isHidden = false
        #expect(card.loopNode.isVisible, "the card's node did not show with the sidebar")
        #expect(sent == ["tip.shown"], "showing the sidebar did not report the notice once: \(sent)")
        host.isHidden = true
        host.isHidden = false
        #expect(sent == ["tip.shown"], "a second show reported the same notice again: \(sent)")
    }

    /// An appearance change while the card is hidden repaints nothing then and once when it shows.
    @Test func aHiddenCardRepaintsItsAppearanceOnceOnShow() {
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
        let window = Self.window(holding: host)
        defer { window.close() }
        let card = SidebarNoticeCardView(frame: NSRect(x: 0, y: 0, width: 240, height: SidebarNoticeCardView.height(for: Self.tip)))
        host.addSubview(card)
        card.configure(Self.tip)
        #expect(card.loopNode.isVisible, "a shown card's node is not visible")
        host.isHidden = true
        card.appearance = NSAppearance(named: .darkAqua)
        card.appearance = NSAppearance(named: .aqua)
        #expect(card.loopNode.deferredCount == 1, "two hidden appearance changes left \(card.loopNode.deferredCount) repaints, not one")
        host.isHidden = false
        #expect(card.loopNode.deferredCount == 0, "the deferred repaint did not run on show")
        card.appearance = NSAppearance(named: .darkAqua)
        #expect(card.loopNode.deferredCount == 0, "a shown card deferred its repaint")
    }

    /// A change of the "Show scroll bars" setting reaches the sidebar through SystemScrollers: the scroller
    /// stays the overlay one and the list fits the clip again.
    @Test func theListFitsTheClipAfterAScrollBarSettingChange() {
        let sidebar = SidebarView(model: SidebarModel(), design: DesignSettings())
        sidebar.frame = NSRect(x: 0, y: 0, width: 260, height: 600)
        sidebar.layoutSubtreeIfNeeded()
        let clipWidth = sidebar.scrollView.contentView.bounds.width
        #expect(clipWidth > 0, "the sidebar's clip has no width")
        sidebar.scrollView.scrollerStyle = .legacy
        sidebar.list.setFrameSize(NSSize(width: 10, height: sidebar.list.frame.height))
        SystemScrollers.systemStyleDidChange()
        #expect(sidebar.scrollView.scrollerStyle == SystemScrollers.nativeStyle, "the sidebar's scroller left the overlay style")
        #expect(sidebar.list.frame.width == sidebar.scrollView.contentView.bounds.width,
                "the list is \(sidebar.list.frame.width) wide, the clip \(sidebar.scrollView.contentView.bounds.width)")
    }

    // MARK: Rule 9: hidden is model only

    /// A collapsed sidebar (its panel hidden) evaluates and draws nothing on a model change, and draws once
    /// when it shows. Before, its `ObservationStream` rendered on every change while hidden.
    @Test func aHiddenSidebarDrawsNothingAndShowingItDrawsOnce() throws {
        let work = MainWorkScheduler(budget: MainFrameBudget())
        let panel = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
        let window = Self.window(holding: panel)
        defer { window.close() }
        let model = SidebarModel()
        let sidebar = SidebarView(model: model, design: DesignSettings(), mainWork: work)
        sidebar.frame = NSRect(x: 0, y: 0, width: 260, height: 400)
        panel.addSubview(sidebar)
        #expect(sidebar.visibility.node.isVisible, "a sidebar in a shown window is not visible")
        panel.isHidden = true
        #expect(!sidebar.visibility.node.isVisible, "hiding the panel did not reach the sidebar's node")
        let hidden = try Self.counts(work, "Sidebar.render")
        for index in 0..<20 { model.filterText = "find \(index)" }
        let changed = try Self.counts(work, "Sidebar.render")
        #expect(changed.evaluations == hidden.evaluations, "a hidden sidebar evaluated what it draws")
        #expect(changed.applies == hidden.applies, "a hidden sidebar drew")
        #expect(sidebar.lastState?.filter == "", "a hidden sidebar drew the new filter")
        panel.isHidden = false
        let shown = try Self.counts(work, "Sidebar.render")
        #expect(shown.showRereads == hidden.showRereads + 1, "showing the sidebar did not read once")
        #expect(shown.applies == hidden.applies + 1, "showing the sidebar did not draw once")
        #expect(sidebar.lastState?.filter == "find 19", "the shown sidebar draws the filter it missed")
    }

    /// The list settings still reach the model while the sidebar is hidden (rule 3): with the rail shown and
    /// the full sidebar collapsed, a change of `sidebar.style` must still change the model's style.
    @Test func aHiddenSidebarStillCarriesItsListSettingsToTheModel() async {
        let work = MainWorkScheduler(budget: MainFrameBudget())
        let panel = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
        let window = Self.window(holding: panel)
        defer { window.close() }
        let model = SidebarModel(), design = DesignSettings()
        let sidebar = SidebarView(model: model, design: design, mainWork: work)
        panel.addSubview(sidebar)
        panel.isHidden = true
        #expect(model.style == .standard)
        design.sidebarSections.style = .rail
        await drainMainTurns()
        #expect(model.style == .rail, "a hidden sidebar left the list settings off the model")
        #expect(sidebar.lastState?.preferences.style == .standard, "a hidden sidebar drew the settings change")
    }

    /// A hidden rail (the full sidebar shown) reads no marks on a model change and draws them once when it shows.
    @Test func aHiddenRailReadsNoMarksAndShowingItDrawsThemOnce() throws {
        let work = MainWorkScheduler(budget: MainFrameBudget())
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
        let window = Self.window(holding: host)
        defer { window.close() }
        let model = SidebarModel(sections: [Self.section(["a"])])
        let rail = SidebarRailView()
        rail.frame = NSRect(x: 0, y: 0, width: 12, height: 400)
        host.addSubview(rail)
        rail.bind(model, on: work)
        #expect(rail.railLayout.ticks.count == 1, "the shown rail did not draw its mark")
        rail.isHidden = true
        #expect(!rail.visibility.node.isVisible, "hiding the rail did not reach its node")
        let hidden = try Self.counts(work, "SidebarRail.marks")
        model.sections = [Self.section(["a", "b", "c"])]
        let changed = try Self.counts(work, "SidebarRail.marks")
        #expect(changed.evaluations == hidden.evaluations, "a hidden rail read its marks")
        #expect(changed.applies == hidden.applies, "a hidden rail drew its marks")
        #expect(rail.railLayout.ticks.count == 1, "a hidden rail laid out the new marks")
        rail.isHidden = false
        let shown = try Self.counts(work, "SidebarRail.marks")
        #expect(shown.showRereads == hidden.showRereads + 1, "showing the rail did not read once")
        #expect(shown.applies == hidden.applies + 1, "showing the rail did not draw once")
        #expect(rail.railLayout.ticks.count == 3, "the shown rail did not draw the marks it missed")
    }

    private static func section(_ ids: [String]) -> SidebarSection {
        SidebarSection(kind: .machine(SidebarMachine(id: .local, name: "This Mac", kind: .local)),
                       nodes: ids.map { .workspace(SidebarWorkspace(id: WorkspaceID($0), title: $0)) })
    }

    private static func counts(_ work: MainWorkScheduler, _ owner: String) throws -> ObservationLedger.Entry {
        try #require(work.observations.snapshot(matching: owner).first { $0.owner == owner })
    }
}
