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

/// The rows of the suite for a list that is kept for each focus context. A hold of the New Tab key asks under two
/// contexts in turn (a page with and without the web view's focus), and a lister that keeps one list reads the
/// catalog again at each change of the context. Each row writes the registry's focus context itself and asks as a
/// page does. No page opens in a row, so no focus effect of the app comes between a row's write and the lister's task;
/// a context that is not the row's in a frame of its ask is the row not making its case (`listed(under:_:)`, in the
/// keys row file).
extension NewTabCommandListKeptTests {
    /// The bare app after one listing to its hand-over: the late turns of the window's first content are over. Returns
    /// the focus context of then, which is a row's first one.
    private static func settled(_ app: App) async throws -> ActionContext {
        let asked = await listed(app.services)
        try #require(asked.list != nil, "setup: the bare app's first listing never handed its list over")
        return app.services.registry.context
    }

    /// A list is kept for each focus context: after a listing under one context and a listing under a second one, a page
    /// that shows under the first context has its list in that turn, and a request under it starts no listing.
    @Test func aRequestUnderAnEarlierFocusContextStartsNoListing() async throws {
        let app = try await Self.shown()
        defer { app.close() }
        let services = app.services, lister = services.newTabActions
        let first = try await Self.settled(app)
        let second = first.symmetricDifference(.webViewFocused)
        let one = try await Self.listed(under: first, services)
        let before = lister.counts
        let two = try await Self.listed(under: second, services)
        let read = lister.counts
        try #require(read.started == before.started + 1, "the row did not make its case: the second context started \(read.started - before.started) listings where 1 is wanted")

        // A page that shows now takes what the lister keeps for the focus context of its turn.
        services.registry.context = first
        let shows = lister.kept
        let again = try await Self.listed(under: first, services)
        let end = lister.counts
        print("new-tab-list: a request under an earlier focus context: \(end.started - read.started) listings started, \(end.actionsRead - read.actionsRead) catalog "
            + "actions read again; the focus contexts \(first.rawValue) and \(second.rawValue); their lists have \(one.actions.count) and \(two.actions.count) rows, "
            + "\(one.actions == two.actions ? "equal" : "not equal"); a page that shows under the first one takes \(shows?.actions.count ?? 0) rows")
        #expect(shows?.actions == one.actions, "a page that shows under the first focus context has \(shows?.actions.count ?? 0) of its \(one.actions.count) actions")
        #expect(end.started == read.started,
                "a request under the first focus context started \(end.started - read.started) listings and read \(end.actionsRead - read.actionsRead) catalog actions again")
        #expect(again.actions == one.actions, "the request under the first focus context did not get the list of that context")
    }

    /// A hold of the New Tab key whose requests come under two focus contexts in turn, one each two frames, after one
    /// list was read under each: no listing starts, and each request gets the list of its own context.
    @Test func aHoldUnderTwoFocusContextsInTurnStartsNoListing() async throws {
        let app = try await Self.shown()
        defer { app.close() }
        let services = app.services, lister = services.newTabActions
        let first = try await Self.settled(app)
        let second = first.symmetricDifference(.webViewFocused)
        let one = try await Self.listed(under: first, services)
        let two = try await Self.listed(under: second, services)
        let before = lister.counts

        var asks: [(context: ActionContext, waiter: Waiter)] = []
        var moved = 0
        for index in 0..<10 {
            let context = index.isMultiple(of: 2) ? first : second
            services.registry.context = context
            asks.append((context, Self.ask(services)))
            // A held key gives a page each 33 ms: two frames at 60 Hz.
            services.mainWork.frameDidFire()
            services.mainWork.frameDidFire()
            if services.registry.context != context { moved += 1 }
        }
        try #require(moved == 0, "the row did not make its case: the focus context was not the row's after the frames of \(moved) of the 10 requests")
        var none = 0, wrong = 0
        for (context, waiter) in asks {
            let asked = await Self.handOver(to: waiter, services)
            let own = context == first ? one : two
            if let list = asked.list {
                if list.actions != own.actions { wrong += 1 }
            } else {
                none += 1
            }
        }
        let end = lister.counts
        print("new-tab-list: a hold under 2 focus contexts in turn: 10 requests, one each 2 frames; \(end.started - before.started) listings started, "
            + "\(end.actionsRead - before.actionsRead) catalog actions read again; \(wrong) requests with the list of the other context, \(none) with no list; "
            + "the focus contexts \(first.rawValue) and \(second.rawValue); their lists have \(one.actions.count) and \(two.actions.count) rows")
        #expect(end.started == before.started,
                "the hold under 2 focus contexts in turn started \(end.started - before.started) listings and read \(end.actionsRead - before.actionsRead) catalog actions again")
        #expect(none == 0, "\(none) of the 10 requests of the hold got no list")
        #expect(wrong == 0, "\(wrong) of the 10 requests of the hold did not get the list of their own focus context")
    }

    /// The lister keeps a list for 4 focus contexts at most: a fifth one drops the oldest list, and only that one. The
    /// last assert (the oldest context reads again) holds with one kept list too: it is the guard of the bound.
    @Test func aFifthFocusContextDropsTheOldestListOnly() async throws {
        let app = try await Self.shown()
        defer { app.close() }
        let services = app.services, lister = services.newTabActions
        let base = try await Self.settled(app)
        let bits: [ActionContext] = [[], .webViewFocused, .rightSidebarFocused, .filePreviewFocused, .homeChannelsEnabled]
        let contexts = bits.map { base.symmetricDifference($0) }
        var started: [Int] = []
        for context in contexts {
            let before = lister.counts.started
            _ = try await Self.listed(under: context, services)
            started.append(lister.counts.started - before)
        }
        let eachOne = started.dropFirst().allSatisfy { $0 == 1 }
        try #require(eachOne, "the row did not make its case: the 5 focus contexts started \(started) listings, where each one after the first starts 1")
        let read = lister.counts

        // The 4 newest, the newest first: each one has its list.
        for context in contexts.dropFirst().reversed() { _ = try await Self.listed(under: context, services) }
        let newest = lister.counts
        // The oldest one was dropped at the fifth.
        _ = try await Self.listed(under: contexts[0], services)
        let end = lister.counts
        print("new-tab-list: a fifth focus context: the 5 contexts \(contexts.map(\.rawValue)) started \(started) listings; requests under the 4 newest: "
            + "\(newest.started - read.started) listings started, \(newest.actionsRead - read.actionsRead) catalog actions read again; a request under the oldest: "
            + "\(end.started - newest.started) listings started")
        #expect(newest.started == read.started,
                "requests under the 4 newest of 5 contexts started \(newest.started - read.started) listings and read \(newest.actionsRead - read.actionsRead) catalog actions again")
        #expect(end.started == newest.started + 1,
                "a request under the oldest of 5 focus contexts started \(end.started - newest.started) listings where 1 is wanted: the lister keeps 4 lists at most")
    }

    /// A change of the registry (here one key binding) drops the list of each focus context: the next request under each
    /// context reads the catalog again. This row holds with one kept list too: it is the guard of a list for each context.
    @Test func aChangeOfTheRegistryDropsTheListOfEachFocusContext() async throws {
        let app = try await Self.shown()
        defer { app.close() }
        let services = app.services, lister = services.newTabActions
        let first = try await Self.settled(app)
        let second = first.symmetricDifference(.webViewFocused)
        _ = try await Self.listed(under: first, services)
        _ = try await Self.listed(under: second, services)
        services.registry.setShortcutOverride(CmuxNextActions.Shortcut("t", modifiers: [.control]), for: "newTab.default")
        let before = lister.counts

        _ = try await Self.listed(under: second, services)
        let newest = lister.counts
        _ = try await Self.listed(under: first, services)
        let end = lister.counts
        print("new-tab-list: a change of a key binding after a list for each of 2 focus contexts: a request under the newest context: "
            + "\(newest.started - before.started) listings started; a request under the older one: \(end.started - newest.started) listings started")
        #expect(newest.started == before.started + 1,
                "after a change of a key binding a request under the newest focus context started \(newest.started - before.started) listings where 1 is wanted")
        #expect(end.started == newest.started + 1,
                "after a change of a key binding a request under the older focus context started \(end.started - newest.started) listings where 1 is wanted")
    }
}
