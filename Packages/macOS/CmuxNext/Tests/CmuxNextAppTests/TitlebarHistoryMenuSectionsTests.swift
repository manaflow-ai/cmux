import AppKit
@testable import CmuxNextApp
import CmuxNextDesign
@testable import CmuxNextHistory
import CmuxNextHistoryDaemon
import CmuxNextWakeups
import CmuxNextPalette
import Foundation
import Testing

/// The titlebar Back / Forward right-click list (history.md 4.2c): the scope's
/// entries, then the window's other places, or every place split by kind.
struct TitlebarHistoryMenuSectionsTests {
    static func place(_ tab: String, workspace: String, content: HistoryLocation.Content = .terminal,
                      page: String? = nil, window: String = "w1") -> HistoryLocation {
        HistoryLocation(key: .init(machine: "m", tab: tab), window: window, workspace: workspace, pane: "p-\(tab)",
                        content: content, title: tab, page: page)
    }

    /// A trail of `places` recorded 10 s apart (no coalescing), cursor on the last.
    static func trail(_ places: [HistoryLocation]) -> LocationTrail {
        var trail = LocationTrail()
        for (step, place) in places.enumerated() {
            _ = trail.record(place, at: Date(timeIntervalSince1970: TimeInterval(step * 10)))
        }
        return trail
    }

    static func titles(_ section: LocationTrailMenuSection) -> [String] { section.items.map(\.entry.location.title) }

    @Test func otherWorkspacesFollowTheScope() {
        let trail = Self.trail([Self.place("a", workspace: "one"), Self.place("b", workspace: "two"),
                                Self.place("c", workspace: "one")])
        let sections = trail.menuSections(.back, scope: .workspace, layout: .scopeThenWindow)
        #expect(sections.map(\.kind) == [.scope, .otherWorkspaces])
        #expect(Self.titles(sections[0]) == ["a"])
        #expect(Self.titles(sections[1]) == ["b"])
    }

    @Test func theScopeLayoutIsTheOldList() {
        let trail = Self.trail([Self.place("b", workspace: "two"), Self.place("c", workspace: "one")])
        #expect(trail.menuSections(.back, scope: .workspace, layout: .scope).isEmpty)
        let window = trail.menuSections(.back, scope: .workspace, layout: .scopeThenWindow)
        #expect(window.map(\.kind) == [.otherWorkspaces])
    }

    @Test func otherWorkspacesListEachPlaceOnceNearestFirst() {
        let trail = Self.trail([Self.place("b", workspace: "two"), Self.place("d", workspace: "three"),
                                Self.place("b", workspace: "two"), Self.place("c", workspace: "one")])
        let others = trail.menuSections(.back, scope: .workspace, layout: .scopeThenWindow).first { $0.kind == .otherWorkspaces }
        #expect(others.map(Self.titles) == ["b", "d"])
        #expect(others?.items.first?.index == 2)
    }

    @Test func windowScopeAddsNoSecondSection() {
        let trail = Self.trail([Self.place("b", workspace: "two"), Self.place("c", workspace: "one")])
        #expect(trail.menuSections(.back, scope: .window, layout: .scopeThenWindow).map(\.kind) == [.scope])
    }

    @Test func otherWindowsStayOut() {
        let trail = Self.trail([Self.place("x", workspace: "two", window: "w2"), Self.place("c", workspace: "one")])
        #expect(trail.menuSections(.back, scope: .workspace, layout: .scopeThenWindow).isEmpty)
    }

    @Test func byKindSplitsBrowserChatsAndTerminals() {
        let trail = Self.trail([
            Self.place("site", workspace: "one", content: .browser),
            Self.place("chat", workspace: "two", content: .other),
            Self.place("shell", workspace: "two"),
            Self.place("store", workspace: "", content: .other, page: "appStore"),
            Self.place("now", workspace: "one"),
        ])
        let sections = trail.menuSections(.back, scope: .workspace, layout: .byKind)
        #expect(sections.map(\.kind) == [.browser, .chatsAndPages, .terminals])
        #expect(sections.map(Self.titles) == [["site"], ["store", "chat"], ["shell"]])
    }

    @Test func forwardListsTheEntriesAfterTheCursor() {
        var trail = Self.trail([Self.place("a", workspace: "one"), Self.place("b", workspace: "two"),
                                Self.place("c", workspace: "one")])
        _ = trail.back(scope: .workspace)
        let sections = trail.menuSections(.forward, scope: .workspace, layout: .scopeThenWindow)
        #expect(sections.map(Self.titles) == [["c"], ["b"]])
    }

    @Test func surfaceScopeLeavesItToThePage() {
        let trail = Self.trail([Self.place("a", workspace: "one"), Self.place("c", workspace: "one")])
        for layout in LocationTrailMenuLayout.allCases {
            #expect(trail.menuSections(.back, scope: .surface, layout: layout).isEmpty)
        }
    }

    @Test func addedSectionsAreCapped() {
        let many = (0..<20).map { Self.place("t\($0)", workspace: "w\($0)") }
        let trail = Self.trail(many + [Self.place("now", workspace: "home")])
        let others = trail.menuSections(.back, scope: .workspace, layout: .scopeThenWindow).first { $0.kind == .otherWorkspaces }
        #expect(others?.items.count == LocationTrail.menuSectionLimit)
        #expect(others?.items.first?.entry.location.title == "t19")
    }
}

/// The list's Recently Closed section, its footer, its row styles, and titles that arrive late
/// (Leo's ask relayed 2026-11-06: right-click Back or Forward lists the direction's history,
/// Recently Closed, and Show Full History).
@MainActor struct TitlebarHistoryMenuContentTests {
    static let now = Date(timeIntervalSince1970: 10_000)

    /// Stands in for the registry's `history.reopen` row.
    static func reopenRow(_ id: String, _ title: String) -> NSMenuItem? { NSMenuItem(title: title, action: nil, keyEquivalent: "") }

    static func closedRow(_ id: String, _ title: String, kind: CmuxNextHistory.ClosedItem.Kind = .terminalTab) -> TitlebarHistoryClosedRow {
        TitlebarHistoryClosedRow(id: id, kind: kind, title: title, detail: "~/src")
    }

    static func sections() -> [LocationTrailMenuSection] {
        let trail = TitlebarHistoryMenuSectionsTests.trail([
            TitlebarHistoryMenuSectionsTests.place("a", workspace: "one"),
            TitlebarHistoryMenuSectionsTests.place("c", workspace: "one"),
        ])
        return trail.menuSections(.back, scope: .workspace, layout: .scopeThenWindow)
    }

    @Test func recentlyClosedSitsBetweenTheTrailAndShowFullHistory() {
        let footer = NSMenuItem(title: "Show History", action: nil, keyEquivalent: "")
        let menu = TitlebarHistoryMenu.make(Self.sections(), closed: .rows([Self.closedRow("daemon:closed_1", "build")]),
                                            choose: { _ in }, reopenRow: TitlebarHistoryMenuContentTests.reopenRow, showAll: footer)
        let titles = menu.items.map { $0.isSeparatorItem ? "—" : $0.title }
        #expect(titles == ["a", "—", "Recently Closed", "build — ~/src", "—", "Show Full History"])
        #expect(menu.items.last === footer)
    }

    /// Each closed row is the registry's `history.reopen` row for its own item's id (asked newest first), never
    /// an inline selector beside the action the palette and Cmd-Shift-T run.
    @Test func aClosedRowReopensItsOwnItem() throws {
        var asked: [String] = []
        let menu = TitlebarHistoryMenu.make([], closed: .rows([Self.closedRow("daemon:closed_new", "new"),
                                                               Self.closedRow("daemon:closed_old", "old")]),
                                            choose: { _ in }, reopenRow: { id, title in
                                                asked.append(id)
                                                return TitlebarHistoryMenuContentTests.reopenRow(id, title)
                                            }, showAll: nil)
        #expect(asked == ["daemon:closed_new", "daemon:closed_old"])
        let old = try #require(menu.items.first { $0.title.hasPrefix("old") })
        #expect(old.identifier?.rawValue == "daemon:closed_old")
        #expect(old.action == nil)
    }

    @Test func anEmptyOrUnservedClosedHistorySaysSo() {
        for (state, text) in [(TitlebarHistoryClosedSection.empty, "Nothing closed yet"),
                              (.unavailable, "Closed items appear once cmux connects")] {
            let menu = TitlebarHistoryMenu.make([], closed: state, choose: { _ in }, reopenRow: TitlebarHistoryMenuContentTests.reopenRow, showAll: nil)
            #expect(menu.items.map(\.title) == ["Recently Closed", text])
            #expect(menu.items.last?.isEnabled == false)
        }
    }

    @Test func closedRowsAreCapped() {
        let rows = (0..<20).map { Self.closedRow("daemon:closed_\($0)", "t\($0)") }
        let menu = TitlebarHistoryMenu.make([], closed: .rows(rows), choose: { _ in }, reopenRow: TitlebarHistoryMenuContentTests.reopenRow, showAll: nil)
        #expect(menu.items.count == 1 + TitlebarHistoryMenu.closedLimit)
    }

    /// Leo 2026-11-06: "don't increase any size ... after adding a recently closed section, don't
    /// shrink it stupidly ... don't baloon it". Every style lists today's history rows unchanged, adds
    /// a bounded Recently Closed, and sets no width of its own.
    @Test func recentlyClosedKeepsTheListsSize() {
        let footer = { NSMenuItem(title: "Show History", action: nil, keyEquivalent: "") }
        let today = TitlebarHistoryMenu.make(Self.sections(), choose: { _ in }, reopenRow: TitlebarHistoryMenuContentTests.reopenRow, showAll: footer())
        let many = (0..<20).map { Self.closedRow("daemon:closed_\($0)", "t\($0)") }
        let todayRows = today.items.filter { $0.action == #selector(TitlebarHistoryMenuTarget.pick(_:)) }.map(\.title)
        for style in TitlebarHistoryMenuStyle.allCases {
            let menu = TitlebarHistoryMenu.make(Self.sections(), closed: .rows(many), style: style, choose: { _ in }, reopenRow: TitlebarHistoryMenuContentTests.reopenRow, showAll: footer())
            #expect(menu.items.filter { $0.action == #selector(TitlebarHistoryMenuTarget.pick(_:)) }.map(\.title) == todayRows)
            let added = menu.items.count - today.items.count
            #expect(added == (style == .submenu ? 2 : 2 + TitlebarHistoryMenu.closedLimit))
            #expect(menu.minimumWidth == today.minimumWidth)
            #expect(menu.items.allSatisfy { $0.attributedTitle == nil })
        }
    }

    /// A long address or path cannot widen the list: closed rows fit the width the history rows set
    /// (or ``TitlebarHistoryMenu/closedMinWidth`` when those are narrower), keeping the title's start and both ends of the detail.
    @Test func aLongClosedDetailDoesNotWidenTheList() throws {
        let url = "https://example.com/" + String(repeating: "deep/", count: 40) + "page.html"
        let row = TitlebarHistoryClosedRow(id: "daemon:closed_1", kind: .browserTab, title: "Docs", detail: url)
        for style in TitlebarHistoryMenuStyle.allCases {
            let today = TitlebarHistoryMenu.make(Self.sections(), choose: { _ in }, reopenRow: TitlebarHistoryMenuContentTests.reopenRow, showAll: nil)
            let menu = TitlebarHistoryMenu.make(Self.sections(), closed: .rows([row]), style: style, choose: { _ in }, reopenRow: TitlebarHistoryMenuContentTests.reopenRow, showAll: nil)
            let items = menu.items + menu.items.flatMap { $0.submenu?.items ?? [] }
            let closed = try #require(items.first { $0.identifier?.rawValue == "daemon:closed_1" })
            let todayWidth = today.items.map { TitlebarHistoryMenu.titleWidth($0.title) }.max() ?? 0
            #expect(TitlebarHistoryMenu.titleWidth(closed.title) <= max(todayWidth, TitlebarHistoryMenu.closedMinWidth))
            #expect(closed.title.hasPrefix("Docs — https://"))
            #expect(closed.title.hasSuffix(".html"))
        }
        let long = TitlebarHistoryClosedRow(id: "daemon:closed_2", kind: .terminalTab, title: String(repeating: "x", count: 200), detail: "~")
        #expect(TitlebarHistoryMenu.closedTitle(long, fitting: 10_000).count == TitlebarHistoryMenu.closedTitleLength)
    }

    @Test func theSubmenuStyleHoldsTheClosedRows() throws {
        let menu = TitlebarHistoryMenu.make([], closed: .rows([Self.closedRow("daemon:closed_1", "build")]), style: .submenu,
                                            choose: { _ in }, reopenRow: TitlebarHistoryMenuContentTests.reopenRow, showAll: nil)
        let item = try #require(menu.items.first)
        #expect(item.title == "Recently Closed")
        #expect(item.submenu?.items.map(\.title) == ["build — ~/src"])
    }

    @Test func aLateTitleRenamesEntriesInPlace() {
        var trail = TitlebarHistoryMenuSectionsTests.trail([
            TitlebarHistoryMenuSectionsTests.place("chat", workspace: "one"),
            TitlebarHistoryMenuSectionsTests.place("b", workspace: "one"),
            TitlebarHistoryMenuSectionsTests.place("chat", workspace: "one"),
            TitlebarHistoryMenuSectionsTests.place("c", workspace: "one"),
        ])
        let before = trail.entries.map(\.location.key)
        let renamed = trail.retitle(.init(machine: "m", tab: "chat"), title: "Fix the build")
        #expect(renamed)
        #expect(trail.entries.map(\.location.key) == before)
        #expect(trail.cursor == 3)
        #expect(trail.entries.map(\.location.title) == ["Fix the build", "b", "Fix the build", "c"])
        let renamedAgain = trail.retitle(.init(machine: "m", tab: "chat"), title: "Fix the build")
        #expect(!renamedAgain)
    }
}

/// A dimmed Back or Forward still opens its list on right-click; its click stays off.
@MainActor struct TitlebarBandButtonDisabledMenuTests {
    static func rightClick() throws -> NSEvent {
        try #require(NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                                        context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    }

    @Test func aDisabledHistoryButtonOpensItsMenu() throws {
        let band = TitlebarToolbarBand(frame: .zero)
        band.historyMenu = { _ in NSMenu(title: "list") }
        band.setHistoryEnabled(back: false, forward: false)
        var shown: [String] = []
        for button in [band.backButton, band.forwardButton] {
            button.presentContextMenu = { menu, _, _ in shown.append(menu.title) }
            button.rightMouseDown(with: try Self.rightClick())
        }
        #expect(shown == ["list", "list"])
    }

    @Test func otherDisabledButtonsStayQuiet() throws {
        let button = TitlebarBandButton(symbol: "sidebar.left")
        button.menuProvider = { NSMenu(title: "list") }
        button.isEnabled = false
        var shown = 0
        button.presentContextMenu = { _, _, _ in shown += 1 }
        button.rightMouseDown(with: try Self.rightClick())
        #expect(shown == 0)
    }
}

/// A history palette page never reads "No Results" for an empty query: a read the daemon did not
/// answer offers Try Again, and an empty Recently Closed says nothing was closed.
@MainActor struct HistoryPaletteStatusTests {
    @Test func anUnansweredReadOffersTryAgain() throws {
        let status = try #require(HistoryRead(entries: [], unavailable: true).status(HistoryQuery(kinds: [.closed])))
        let row = HistoryPalettePages.statusItem(status)
        #expect(row.id == "history.status.unavailable")
        #expect(row.isEnabled)
        #expect(row.primary.togglesInPlace)
    }

    @Test func anEmptyRecentlyClosedSaysSo() throws {
        let status = try #require(HistoryRead(entries: []).status(HistoryQuery(kinds: [.closed])))
        #expect(status.id == "history.status.empty")
        #expect(!HistoryPalettePages.statusItem(status).isEnabled)
        #expect(HistoryRead(entries: []).status(HistoryQuery(kinds: [.page])) == nil)
    }

    @Test func rowsNeedNoStatus() {
        let entry = HistoryEntry(id: "closed:daemon:closed_1", kind: .closed, time: Date(), title: "build",
                                 payload: .closed(CmuxNextHistory.ClosedItem(id: "daemon:closed_1", kind: .terminalTab, title: "build", machine: "local")))
        #expect(HistoryRead(entries: [entry]).status(HistoryQuery(kinds: [.closed])) == nil)
    }

    /// A failed read stays visible under the rows other owners gave, and a search with no match is the
    /// palette's own "No Results", not "Nothing closed yet".
    @Test func aPartialReadStillSaysItFailedAndASearchIsNotEmptyHistory() {
        let entry = HistoryEntry(id: "closed:daemon:closed_1", kind: .closed, time: Date(), title: "build",
                                 payload: .closed(CmuxNextHistory.ClosedItem(id: "daemon:closed_1", kind: .terminalTab, title: "build", machine: "local")))
        #expect(HistoryRead(entries: [entry], unavailable: true).status(HistoryQuery())?.id == "history.status.unavailable")
        #expect(HistoryRead(entries: []).status(HistoryQuery(text: "zzz", kinds: [.closed])) == nil)
        #expect(HistoryRead(entries: []).status(HistoryQuery(kinds: [.closed], range: .hour)) == nil)
    }

    static let quick = Backoff(initial: .milliseconds(1), maximum: .milliseconds(1), jitter: 0)

    @Test func aReadIsRetriedABoundedNumberOfTimes() async {
        var calls = 0
        let none: Int? = await DaemonHistoryClient.retrying(attempts: 3, backoff: Self.quick) {
            calls += 1
            throw CancellationError()
        }
        #expect(none == nil)
        #expect(calls == 3)
        calls = 0
        let second = await DaemonHistoryClient.retrying(attempts: 3, backoff: Self.quick) { () throws -> Int in
            calls += 1
            if calls < 2 { throw CancellationError() }
            return 7
        }
        #expect(second == 7)
        #expect(calls == 2)
    }

    @Test func closedRowsBecomeTheMenuSection() {
        let entry = HistoryEntry(id: "closed:daemon:closed_1", kind: .closed, time: Date(), title: "build", detail: "~/src",
                                 machineName: "lane-2",
                                 payload: .closed(CmuxNextHistory.ClosedItem(id: "daemon:closed_1", kind: .terminalTab, title: "build", machine: "lane-2")))
        #expect(TitlebarHistoryClosedSection([entry], served: false) == .unavailable)
        #expect(TitlebarHistoryClosedSection([], served: true) == .empty)
        guard case .rows(let rows) = TitlebarHistoryClosedSection([entry], served: true) else { return #expect(Bool(false)) }
        #expect(rows.map(\.id) == ["daemon:closed_1"])
        #expect(rows.first?.detail == "~/src · lane-2")
    }
}
