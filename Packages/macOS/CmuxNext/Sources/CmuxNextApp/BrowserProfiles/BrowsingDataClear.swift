import CmuxNextActions
import CmuxNextBrowser
import CmuxNextHistory
import CmuxNextWakeups
import Foundation
import os

/// Clear Browsing Data (cx-d0d.23, Chrome's): one profile's browsing
/// history, cookies and site data, and cached images and files changed in a
/// time range, in both engines. One action (`browserProfile.clearBrowsingData`)
/// serves the palette, the profile's context menu, Settings > Browser >
/// Profiles, `cmux browser-profile clear-browsing-data` and MCP. The range
/// is asked for (the palette's inline prompt); every kind unless the
/// invocation turns one off.
@MainActor
enum BrowsingDataClear {
    struct Kinds: OptionSet {
        let rawValue: Int
        static let history = Kinds(rawValue: 1)
        static let cookies = Kinds(rawValue: 2)
        static let cache = Kinds(rawValue: 4)

        /// The kinds an invocation asks for: each `history`, `cookies` and
        /// `cache` argument that is not false.
        init(_ invocation: ActionInvocation) {
            var kinds: Kinds = []
            for (name, kind) in [("history", Kinds.history), ("cookies", .cookies), ("cache", .cache)]
            where invocation[name]?.boolValue != false {
                kinds.insert(kind)
            }
            self = kinds
        }

        init(rawValue: Int) { self.rawValue = rawValue }
    }

    static let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "browser-profiles")

    static func bind(_ bind: BrowserProfileOpenHandlers.Bind, context: AppActionContext) {
        bind("browserProfile.clearBrowsingData") { invocation in
            try run(Kinds(invocation), invocation, context, defaultRange: .hour)
        }
    }

    /// Clear Browser History (`palette.browserClearHistory`, `cmux browser
    /// clear-history`): the history part of Clear Browsing Data for the
    /// named or focused tab's profile, over all time unless `range` says.
    static func bindClearHistory(_ registry: ActionRegistry, context: AppActionContext) {
        registry.bind("palette.browserClearHistory", run: { invocation in
            try run(.history, invocation, context, defaultRange: .all)
        })
    }

    /// Resolves the invocation's profile and range, then clears `kinds`.
    private static func run(_ kinds: Kinds, _ invocation: ActionInvocation, _ context: AppActionContext,
                            defaultRange: HistoryRange) throws {
        // An incognito window's tab names no profile (its data goes with the window): never the default's.
        let named = invocation.target?.kind == .browserProfile || invocation["browserProfile"] != nil
        if !named, let (tab, _) = context.focusedBrowserTab(), context.services.cache.browserTabs.isIncognitoTab(tab.id) {
            throw ActionFailure.invalidTarget(BrowserProfileAppStrings.incognitoTab)
        }
        let profile = try context.browserProfile(invocation).engineProfile
        let range = invocation["range"]?.stringValue.flatMap(HistoryRange.init(rawValue:)) ?? defaultRange
        clear(kinds, of: profile, in: range, context.services)
    }

    /// Clears `kinds` of `profile` changed in `range`: page visits on the
    /// daemon (restorable) and in the omnibar's memory; cookies, site data
    /// and caches in the profile's WebKit store and Chromium profile.
    static func clear(_ kinds: Kinds, of profile: BrowserProfileID, in range: HistoryRange, _ services: AppServices) {
        if kinds.contains(.history) { services.history.clearPages(profile: profile, range: range) }
        let cookies = kinds.contains(.cookies), cache = kinds.contains(.cache)
        guard cookies || cache else { return }
        let since = range.start(now: Date())
        let webKit = services.cache.webKit.profileStore
        let cef = services.cache.cef, work = services.work
        let liveTabs = services.cache.browsers.values.compactMap { $0.tab as? CEFTab }.filter { $0.profileID == profile }
        let logger = Self.logger
        // task-owner: one clear of one profile's stores; ends when both engines answer. R-hop: a nonisolated task at
        // the priority of the person's clear awaits the engines' clears; nothing applies on main after them.
        services.work.task(.userBlocking) {
            await webKit.clearBrowsingData(for: profile, siteData: cookies, cache: cache, since: since)
            do {
                try await cef.clearBrowsingData(profile, cookies: cookies, cache: cache, since: since, liveTabs: liveTabs, work: work)
            } catch {
                logger.error("Chromium clear browsing data failed: \(String(describing: error), privacy: .public)")
            }
        }
    }
}
