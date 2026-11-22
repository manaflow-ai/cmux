import AppKit
@testable import CmuxNextActions
@testable import CmuxNextAgentPane
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import CmuxNextDesign
@testable import CmuxNextSettings
import CmuxNextTabs
import CmuxNextTestSupport
import Foundation
import Testing

/// The rows of the suite for what a kept list's key holds and what it lacks. The key is the focus context and the
/// registry's count of changes. A state that an action's own rule reads (the title of a toggle) is no part of it, and a
/// listing that saw two focus contexts or a change of the registry has no key. A row that needs a second focus context
/// writes the registry's context itself, as a Return to a terminal changes it; the fixture has no terminal.
extension NewTabCommandListKeptTests {
    /// The focus contexts that the frames of one ask ran under, as numbers.
    @MainActor private final class ContextsSeen { var values: Set<UInt32> = [] }

    /// The focus context of a terminal tab in place of the page's, made from the page's context `page`.
    private static func terminal(_ page: ActionContext) -> ActionContext {
        let away = page.subtracting([.agentPaneFocused, .webViewFocused]).union(.terminalFocused)
        return away == page ? page.symmetricDifference(.agentPaneFocused) : away
    }

    /// Asks for the list under `context`, as a page does, and is the display to the hand-over. The row's write must hold
    /// in each frame of the ask and after its hand-over.
    static func listed(under context: ActionContext, _ services: AppServices) async throws -> Listed {
        let seen = ContextsSeen()
        services.registry.context = context
        let asked = await listed(services) { _ = seen.values.insert(services.registry.context.rawValue) }
        _ = seen.values.insert(services.registry.context.rawValue)
        let others = seen.values.subtracting([context.rawValue]).sorted()
        try #require(others.isEmpty, "the row did not make its case: it wrote the focus context \(context.rawValue), and the frames of its ask had \(others) too")
        return try #require(asked.list, "no hand-over under the focus context \(context.rawValue)")
    }

    /// Is the display until the listing that starts after `before` has read slices: the frame of its first task and two
    /// more. The listing must not be at its end then.
    private static func slices(_ services: AppServices, after before: AgentPaneNewTabActions.Counts) throws {
        let lister = services.newTabActions, limit = frameLimit(services)
        var fired = 0
        while lister.counts.started == before.started, fired < limit {
            services.mainWork.frameDidFire()
            fired += 1
        }
        try #require(lister.counts.started == before.started + 1,
                     "the row did not make its case: \(lister.counts.started - before.started) listings started in \(fired) frames where 1 is wanted")
        services.mainWork.frameDidFire()
        services.mainWork.frameDidFire()
        try #require(lister.counts.actionsRead == before.actionsRead && services.mainWork.frames.activeClients.contains(Self.lister),
                     "the row did not make its case: the listing was at its end 2 frames after its first task")
    }

    /// The first letter in `page`, then the display while the lister has a task and no listing started. Returns how many
    /// listings the letter started; the listing is read to its hand-over before the return.
    private static func firstLetter(in page: NativeNewTabModel, _ services: AppServices) async -> (queued: Bool, started: Int) {
        let lister = services.newTabActions, before = lister.counts, limit = frameLimit(services)
        page.text = "a"
        let queued = services.mainWork.frames.activeClients.contains(Self.lister)
        var fired = 0
        while lister.counts.started == before.started, services.mainWork.frames.activeClients.contains(Self.lister), fired < limit {
            services.mainWork.frameDidFire()
            fired += 1
        }
        let started = lister.counts.started - before.started
        // The row's own ask comes after the count: it joins the letter's listing, or it is the only ask.
        _ = await listed(services)
        return (queued, started)
    }

    /// Binds the app's Collapse Tabs row on a store of the row's own. The row's title is made from the store's state,
    /// which is no member of the registry. Returns the store and the row's id.
    static func collapseRow(_ services: AppServices) throws -> (store: WorkspaceVerticalTabs, id: String) {
        var context = AppActionContext(services: services)
        let design = DesignSettings()
        design.verticalTabs = true
        context.design = design
        let store = WorkspaceVerticalTabs(defaults: try #require(UserDefaults(testSuiteName: "NewTabCommandListKeptTests.\(UUID().uuidString)")))
        VerticalTabsActions(host: context, store: store).bind(into: services.registry)
        try #require(!store.isCollapsed, "setup: the row's own store starts collapsed")
        return (store, VerticalTabsActions.collapse.rawValue)
    }

    private static func host(in view: NSView) -> NativeNewTabHostingView? {
        if let host = view as? NativeNewTabHostingView { return host }
        return view.subviews.lazy.compactMap { host(in: $0) }.first
    }

    /// Cmd-T with no page prepared: the view of the page's tab makes the page's model. Returns that model. The view can
    /// come in a later presentation turn; that wait is the fixture's (a bound of time), not a row's.
    private static func openColdPage(_ app: App) async throws -> NativeNewTabModel {
        let services = app.services
        services.newTabSpares.dropAll()
        try #require(services.newTabSpares.nativeSpare == nil, "setup: a native New Tab page is still prepared")
        let key = try #require(NewTabPage.openNative(in: app.pane, reusingShown: false), "the native New Tab page is off")
        try await PinnedPageTests.until({ app.pane.currentTabKey == key && services.pages.existingView(key).flatMap { host(in: $0) } != nil },
                                        report: { "the page that Cmd-T made with no prepared page never had its view" })
        return try #require(services.pages.existingView(key).flatMap { host(in: $0) }?.model, "the page of tab \(key) has no model")
    }

    // MARK: - A state that is no part of the key

    /// A page that shows with the kept list has the rows of the last listing. The title of a toggle is made from a state
    /// that the key does not hold (here the app's Collapse Tabs row, on a store of the row's own). The state changes with
    /// no write of the registry, so the list is still kept, and the page's row has the old title: Return on it runs
    /// nothing, and the actions are read again, so the row shows the title of now.
    @Test func aRunOfARowWithAnOldTitleRunsNothingAndTheRowShowsTheNewTitle() async throws {
        let app = try await Self.shown()
        defer { app.close() }
        let services = app.services, lister = services.newTabActions
        let (store, id) = try Self.collapseRow(services)

        let first = try Self.openPage(app)
        first.loadPaletteActions()
        let cold = await Self.listed(services)
        let list = try #require(cold.list, "the first page's listing never handed its list over")
        let page = try Self.openPage(app)
        try #require(page.page.omnibar.actions == list.actions, "the row did not make its case: the second page did not show with the kept list")
        let row = page.page.omnibar.actions.first { $0.id == id }
        let shown = try #require(row, "the row did not make its case: the kept list of \(list.actions.count) rows has no row \(id)")
        // The state that the row's title is made from changes. No member of the registry is written; the focus is the same.
        store.setCollapsed(true)
        try #require(lister.kept?.actions == list.actions, "the row did not make its case: the change of the state dropped the kept list")
        let before = lister.counts

        // Return on the row, or a click on it.
        page.activate(.action(shown))
        let ran = !store.isCollapsed
        let read = await Self.listed(services)
        let end = lister.counts
        let now = page.page.omnibar.actions.first { $0.id == id }
        print("new-tab-list: a run of a row with an old title: the row showed '\(shown.title)', the run \(ran ? "ran it" : "ran nothing"), "
            + "\(end.started - before.started) listings started after it, the row shows '\(now?.title ?? "no row")' after the hand-over")
        #expect(!ran, "the row showed '\(shown.title)' with the tabs collapsed, and its run expanded them")
        #expect(read.list != nil && end.started == before.started + 1, "the run started \(end.started - before.started) listings where 1 is wanted")
        #expect(now != nil && now?.title != shown.title, "after the run the row shows '\(now?.title ?? "no row")', and it showed '\(shown.title)' before")
    }

    /// The other half of the title's compare: the state did not change since the listing, so the page's row shows the
    /// title of now, and Return on it runs the row.
    @Test func aRunOfARowWithTheTitleOfNowRunsIt() async throws {
        let app = try await Self.shown()
        defer { app.close() }
        let services = app.services
        let (store, id) = try Self.collapseRow(services)
        let page = try Self.openPage(app)
        page.loadPaletteActions()
        let list = try #require(await Self.listed(services).list, "the page's listing never handed its list over")
        let row = page.page.omnibar.actions.first { $0.id == id }
        let shown = try #require(row, "the row did not make its case: the page has \(page.page.omnibar.actions.count) of \(list.actions.count) rows and no row \(id)")

        page.activate(.action(shown))
        print("new-tab-list: a run of a row with the title of now: the row showed '\(shown.title)', the run \(store.isCollapsed ? "ran it" : "ran nothing")")
        #expect(store.isCollapsed, "the row showed '\(shown.title)', the title of now, and its run did not collapse the tabs")
    }

    /// A page whose own listing read its list asks for nothing at its first use. So after a run that the palette
    /// refuses, only the page's list itself asks for the read. Both kinds of page: the prepared one that Cmd-T adopts,
    /// and the one that Cmd-T makes when no page is prepared.
    @Test(arguments: [true, false])
    func aRefusedRunInAPageWithItsOwnListReadsTheActionsAgain(prepared: Bool) async throws {
        let app = try await Self.shown()
        defer { app.close() }
        let services = app.services, lister = services.newTabActions
        let (store, id) = try Self.collapseRow(services)
        try #require(lister.kept == nil, "the row did not make its case: a list is kept before the page's open")
        let before = lister.counts
        let page = try await prepared ? Self.openPage(app) : Self.openColdPage(app)
        page.loadPaletteActions()
        let handed = try #require(await Self.listed(services).list, "the page's listing never handed its list over")
        let own = lister.counts
        // One listing since the open, with a key, and the page has its list: the page counts the list as its own.
        let has = page.page.omnibar.actions.count, keeps = lister.kept == nil ? "no list is kept" : "a list is kept"
        try #require(own.started == before.started + 1 && lister.kept?.actions == handed.actions && page.page.omnibar.actions == handed.actions,
                     "the row did not make its case: \(own.started - before.started) listings started, \(keeps), the page has \(has) of \(handed.actions.count) actions")
        let row = page.page.omnibar.actions.first { $0.id == id }
        let shown = try #require(row, "the row did not make its case: the list of \(handed.actions.count) rows has no row \(id)")
        store.setCollapsed(true)
        try #require(lister.kept?.actions == handed.actions, "the row did not make its case: the change of the state dropped the kept list")

        page.activate(.action(shown))
        let ran = !store.isCollapsed
        // The row's own ask takes the kept list with no read, when the run asked for none.
        let read = await Self.listed(services)
        let end = lister.counts
        let now = page.page.omnibar.actions.first { $0.id == id }
        print("new-tab-list: a refused run in a page with its own list (\(prepared ? "a prepared page" : "no prepared page")): the row showed "
            + "'\(shown.title)', the run \(ran ? "ran it" : "ran nothing"), \(end.started - own.started) listings started after it, "
            + "the row shows '\(now?.title ?? "no row")' after the hand-over")
        #expect(!ran, "the row showed '\(shown.title)' with the tabs collapsed, and its run expanded them")
        #expect(read.list != nil && end.started == own.started + 1, "the refused run started \(end.started - own.started) listings where 1 is wanted")
        #expect(now != nil && now?.title != shown.title, "after the refused run the row shows '\(now?.title ?? "no row")', and it showed '\(shown.title)' before")
    }

    // MARK: - A listing that has no key

    /// The usual use of a page: a letter, then Return to a terminal before the letter's listing is at its end. That
    /// listing saw two focus contexts, so it is not kept. The list that was kept before it stays: the next page shows
    /// with it and starts no listing.
    @Test func aListingThatEndsUnderAnotherFocusContextDoesNotDropTheKeptList() async throws {
        let app = try await Self.shown()
        defer { app.close() }
        let services = app.services, lister = services.newTabActions
        let first = try Self.openPage(app)
        first.loadPaletteActions()
        let cold = await Self.listed(services)
        let list = try #require(cold.list, "the first page's listing never handed its list over")
        let home = services.registry.context, away = Self.terminal(home)
        let page = try Self.openPage(app)
        try #require(page.page.omnibar.actions == list.actions, "the row did not make its case: the second page did not show with the kept list")
        let before = lister.counts

        // The first letter asks for a read. Return comes while the listing reads: the focus goes to a terminal.
        page.text = "l"
        try Self.slices(services, after: before)
        let mixed = try await Self.listed(under: away, services)
        let read = lister.counts
        try #require(read.started == before.started + 1, "the row did not make its case: \(read.started - before.started) listings started where 1 is wanted")
        try #require(lister.kept == nil, "the row did not make its case: the letter's listing read each action under the second focus context")

        // The next New Tab page: the focus is a page's again.
        services.registry.context = home
        let next = try Self.openPage(app)
        let has = next.page.omnibar.actions.count
        next.loadPaletteActions()
        let again = await Self.listed(services)
        let end = lister.counts
        print("new-tab-list: a listing that ends under another focus context: its list is \(mixed.actions == list.actions ? "equal to" : "not equal to") the kept one; "
            + "the next page shows with \(has) of \(list.actions.count) actions, \(end.started - read.started) listings started, "
            + "\(end.actionsRead - read.actionsRead) catalog actions read again; the focus contexts \(home.rawValue) and \(away.rawValue)")
        #expect(next.page.omnibar.actions == list.actions && has == list.actions.count,
                "the next page showed with \(has) of the \(list.actions.count) actions: the kept list was dropped")
        #expect(again.list != nil && end.started == read.started,
                "the next page started \(end.started - read.started) listings and read \(end.actionsRead - read.actionsRead) catalog actions again")
    }

    /// A page that joins a listing which saw two focus contexts takes a list that no key holds for. As a page that takes
    /// the kept list, it reads the actions again at its first letter.
    @Test func aPageThatJoinedAListingOfTwoFocusContextsReadsAgainAtItsFirstLetter() async throws {
        let app = try await Self.shown()
        defer { app.close() }
        let services = app.services, lister = services.newTabActions
        let first = try Self.openPage(app)
        let home = services.registry.context, away = Self.terminal(home)
        let before = lister.counts
        first.loadPaletteActions()
        try Self.slices(services, after: before)
        services.registry.context = away
        services.mainWork.frameDidFire()
        try #require(lister.counts.actionsRead == before.actionsRead, "the row did not make its case: the listing was at its end before the second page")
        // The second page shows while the listing reads: it has no list, and its ask joins that listing.
        let page = try Self.openPage(app)
        try #require(page.page.omnibar.actions.isEmpty, "the row did not make its case: the second page showed with \(page.page.omnibar.actions.count) actions")
        page.loadPaletteActions()
        let handed = try #require(await Self.listed(services).list, "the listing never handed its list over")
        let read = lister.counts
        try #require(read.started == before.started + 1 && page.page.omnibar.actions == handed.actions && !handed.actions.isEmpty,
                     "the row did not make its case: \(read.started - before.started) listings started, the second page has \(page.page.omnibar.actions.count) actions")
        services.registry.context = away
        try #require(lister.kept == nil, "the row did not make its case: the listing read each action under the second focus context")
        services.registry.context = home

        let letter = await Self.firstLetter(in: page, services)
        print("new-tab-list: a page that joined a listing of 2 focus contexts: its first letter \(letter.queued ? "queued" : "did not queue") a task of "
            + "the lister, \(letter.started) listings started; the focus contexts \(home.rawValue) and \(away.rawValue)")
        #expect(letter.queued, "the first letter queued no task of the lister")
        #expect(letter.started == 1, "the first letter in a page with a list of 2 focus contexts started \(letter.started) listings where 1 is wanted")
    }

    /// A change of the registry while a listing reads: the list has no key, and the page that takes it reads the actions
    /// again at its first letter.
    @Test func aPageWhoseListingSawAChangeOfTheRegistryReadsAgainAtItsFirstLetter() async throws {
        let app = try await Self.shown()
        defer { app.close() }
        let services = app.services, lister = services.newTabActions
        let page = try Self.openPage(app)
        let before = lister.counts
        page.loadPaletteActions()
        try Self.slices(services, after: before)
        services.registry.setShortcutOverride(CmuxNextActions.Shortcut("t", modifiers: [.control]), for: "newTab.default")
        let handed = try #require(await Self.listed(services).list, "the listing never handed its list over")
        let read = lister.counts
        try #require(read.started == before.started + 1 && page.page.omnibar.actions == handed.actions && !handed.actions.isEmpty,
                     "the row did not make its case: \(read.started - before.started) listings started, the page has \(page.page.omnibar.actions.count) actions")
        #expect(lister.kept == nil, "a list whose listing saw a change of the registry is kept")

        let letter = await Self.firstLetter(in: page, services)
        print("new-tab-list: a page whose listing saw a change of a key binding: its first letter \(letter.queued ? "queued" : "did not queue") a task "
            + "of the lister, \(letter.started) listings started")
        #expect(letter.queued, "the first letter queued no task of the lister")
        #expect(letter.started == 1, "the first letter in a page whose listing saw a change of the registry started \(letter.started) listings where 1 is wanted")
    }

    /// A change after a listing's last slice, while its list waits for the hand-over: the list's key holds no more
    /// when the page takes it, and the page reads the actions again at its first letter. Both parts of the key: a write
    /// of the registry, and another focus context.
    @Test(arguments: [true, false])
    func aPageWhoseListWaitedForItsHandOverAtAChangeReadsAgainAtItsFirstLetter(ofTheRegistry: Bool) async throws {
        let app = try await Self.shown()
        defer { app.close() }
        let services = app.services, lister = services.newTabActions, limit = Self.frameLimit(services)
        // The late turns of the window's first content are over after one listing. A write drops that listing's list.
        _ = await Self.listed(services)
        services.registry.setShortcutOverride(CmuxNextActions.Shortcut("t", modifiers: [.control]), for: "newTab.default")
        let page = try Self.openPage(app)
        try #require(page.page.omnibar.actions.isEmpty, "the row did not make its case: the page showed with \(page.page.omnibar.actions.count) actions")
        let before = lister.counts
        page.loadPaletteActions()
        try Self.slices(services, after: before)
        var fired = 0
        while lister.counts.actionsRead == before.actionsRead, fired < limit {
            services.mainWork.frameDidFire()
            fired += 1
        }
        let ended = lister.counts.actionsRead - before.actionsRead
        try #require(ended > 0 && page.page.omnibar.actions.isEmpty,
                     "the row did not make its case: after \(fired) frames the listing read \(ended) actions to its end, and the page has \(page.page.omnibar.actions.count) actions")
        // The listing is at its end and its list is not handed over yet: the change comes now.
        let home = services.registry.context, away = Self.terminal(home), what = ofTheRegistry ? "a key binding" : "the focus context"
        if ofTheRegistry {
            services.registry.setShortcutOverride(CmuxNextActions.Shortcut("y", modifiers: [.control]), for: "newTab.default")
        } else {
            services.registry.context = away
        }
        let handed = try #require(await Self.listed(services).list, "the listing never handed its list over")
        let read = lister.counts, held = ofTheRegistry || services.registry.context == away, has = page.page.omnibar.actions.count
        try #require(read.started == before.started + 1 && page.page.omnibar.actions == handed.actions && !handed.actions.isEmpty && held,
                     "the row did not make its case: \(read.started - before.started) listings started, the page has \(has) actions, the focus context is \(services.registry.context.rawValue)")
        #expect(lister.kept == nil, "a list that waited for its hand-over at a change of \(what) is kept after that change")
        // The next letter comes with the focus in the page again.
        services.registry.context = home

        let letter = await Self.firstLetter(in: page, services)
        print("new-tab-list: a page whose list waited for its hand-over at a change of \(what): the listing's end after \(fired) more frames; "
            + "its first letter \(letter.queued ? "queued" : "did not queue") a task of the lister, \(letter.started) listings started")
        #expect(letter.queued, "the first letter queued no task of the lister")
        #expect(letter.started == 1, "the first letter in a page whose list waited at a change of \(what) started \(letter.started) listings where 1 is wanted")
    }

    // MARK: - A page that Cmd-T makes with no prepared page

    /// No page is prepared, so the view of the new tab makes the page's model. As a prepared page, it shows with the
    /// kept list and starts no listing, and its first letter reads the actions again.
    @Test func aPageWithNoPreparedPageShowsWithTheKeptListAndReadsAgainAtItsFirstLetter() async throws {
        let app = try await Self.shown()
        defer { app.close() }
        let services = app.services, lister = services.newTabActions
        let first = try Self.openPage(app)
        first.loadPaletteActions()
        let list = try #require(await Self.listed(services).list, "the first page's listing never handed its list over")
        try #require(lister.kept?.actions == list.actions, "the row did not make its case: no list is kept before the second page")
        let before = lister.counts

        let page = try await Self.openColdPage(app)
        try #require(page !== first, "the row did not make its case: the second key showed the first page's model")
        let has = page.page.omnibar.actions.count, same = page.page.omnibar.actions == list.actions
        let shown = lister.counts
        let letter = await Self.firstLetter(in: page, services)
        print("new-tab-list: a page with no prepared page: it shows with \(has) of \(list.actions.count) actions, \(shown.started - before.started) "
            + "listings started at its show; its first letter \(letter.queued ? "queued" : "did not queue") a task of the lister, \(letter.started) listings started")
        #expect(same && has == list.actions.count, "the page showed with \(has) of the \(list.actions.count) actions of the kept list")
        #expect(shown.started == before.started, "the show of the page started \(shown.started - before.started) listings")
        #expect(letter.queued, "the first letter queued no task of the lister")
        #expect(letter.started == 1, "the first letter in a page that showed with the kept list started \(letter.started) listings where 1 is wanted")
    }

    // MARK: - The key's two parts

    /// The focus context is a part of the key: a page that shows under another context than the kept list's takes no
    /// list, and a request under it reads the catalog.
    @Test func aRequestUnderANewFocusContextReadsTheCatalog() async throws {
        let app = try await Self.shown()
        defer { app.close() }
        let services = app.services, lister = services.newTabActions
        let first = try Self.openPage(app)
        first.loadPaletteActions()
        let list = try #require(await Self.listed(services).list, "the first page's listing never handed its list over")
        let home = services.registry.context, away = Self.terminal(home)
        try #require(lister.kept?.actions == list.actions, "the row did not make its case: no list is kept under the first focus context")
        let before = lister.counts

        services.registry.context = away
        let shows = lister.kept
        let other = try await Self.listed(under: away, services)
        let end = lister.counts
        print("new-tab-list: a request under a new focus context: a page that shows under it takes \(shows?.actions.count ?? 0) rows, "
            + "\(end.started - before.started) listings started; the focus contexts \(home.rawValue) and \(away.rawValue); their lists have "
            + "\(list.actions.count) and \(other.actions.count) rows, \(list.actions == other.actions ? "equal" : "not equal")")
        #expect(shows == nil, "a page that shows under a new focus context takes the \(shows?.actions.count ?? 0) rows of another context")
        #expect(end.started == before.started + 1, "a request under a new focus context started \(end.started - before.started) listings where 1 is wanted")
    }

    /// Each of the 7 members of the registry that a row's face is read from is a part of the key: one write of it drops
    /// the kept list, in the write's own turn. After each write the row reads a list again, which is kept.
    @Test func aWriteOfEachMemberOfTheRegistryDropsTheKeptList() async throws {
        let app = try await Self.shown()
        defer { app.close() }
        let services = app.services, lister = services.newTabActions, registry = services.registry
        let id: ActionID = "newTab.default"
        let key = CmuxNextActions.Shortcut("t", modifiers: [.control]), other = CmuxNextActions.Shortcut("y", modifiers: [.control])
        var changed = try #require(registry.descriptors.first, "setup: the catalog has no descriptor")
        changed.waitsForKeyedCreate.toggle()
        let descriptor = changed
        // The late turns of the window's first content are over after one listing.
        _ = await Self.listed(services)
        let action = try #require(registry.actions.first, "setup: the registry has no bound action")
        // The feature's write is the last one: the app can bind actions after it.
        let writes: [(member: String, write: @MainActor () -> Void)] = [
            ("the catalog", { registry.seed([descriptor]) }),
            ("the bound actions", { registry.register(action) }),
            ("the shortcut overrides", { registry.shortcutOverrides[id] = key }),
            ("the chord overrides", { registry.chordOverrides[id] = ShortcutChord(key, other) }),
            ("the alternate shortcuts", { registry.alternateShortcuts[id] = [[other]] }),
            ("the key binding layers", { registry.keyBindingLayers.ghosttyClaims = [other] }),
            ("the features that are off", { registry.disabledFeatures.insert(.mcp) }),
        ]
        var kept: [String] = [], started: [Int] = []
        for (member, write) in writes {
            let before = lister.counts
            let asked = await Self.listed(services)
            try #require(asked.list != nil && lister.kept != nil, "the row did not make its case: no list is kept before the write of \(member)")
            started.append(lister.counts.started - before.started)
            write()
            if lister.kept != nil { kept.append(member) }
        }
        print("new-tab-list: a write of each of 7 members of the registry: the listings started before each write \(started); "
            + "a list still kept after the write of: \(kept.isEmpty ? "none" : kept.joined(separator: ", "))")
        #expect(kept.isEmpty, "a list is still kept after a write of: \(kept.joined(separator: ", "))")
        let eachOne = started.dropFirst().allSatisfy { $0 == 1 }
        #expect(eachOne, "the request after each write started \(started.dropFirst()) listings where 1 each is wanted")
    }
}
