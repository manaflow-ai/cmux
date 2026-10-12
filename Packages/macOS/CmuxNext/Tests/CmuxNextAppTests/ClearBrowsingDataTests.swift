import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextBrowser
import Foundation
import Testing
import WebKit

/// cx-d0d.23, Chrome's Clear Browsing Data: one action
/// (`browserProfile.clearBrowsingData`, the palette, Settings > Browser >
/// Profiles, `cmux browser-profile clear-browsing-data` and MCP) clears a
/// profile's history, cookies and site data, and cache over a time range.
/// Runs the app's action registry as the palette and the CLI reach it, on
/// the profile's real WebKit store.
@MainActor @Suite(.serialized, .timeLimit(.minutes(2)))
struct ClearBrowsingDataTests {
    static let site = "cbd-test.example"

    @Test func clearingTheLastHourRemovesTheChosenKindsOfAProfilesData() async throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        let store = services.cache.webKit.profileStore.dataStore(for: .default)
        let cookie = try #require(HTTPCookie(properties: [.domain: Self.site, .path: "/", .name: "cbd", .value: "1",
                                                          .expires: Date().addingTimeInterval(3600)]))
        await store.httpCookieStore.setCookie(cookie)
        let page = try #require(URL(string: "https://\(Self.site)/visited"))
        services.cache.history.recordVisit(url: page, title: "Visited", at: Date())
        let target = ActionTargetRef(kind: .browserProfile, id: BrowserProfileRecord.defaultID)
        #expect(services.registry.descriptor(for: "browserProfile.clearBrowsingData") != nil, "Clear Browsing Data is not an action")

        // History only: the visit goes, the cookie stays.
        let historyOnly = ActionInvocation(target: target, arguments: [
            "range": .string("hour"), "history": .bool(true), "cookies": .bool(false), "cache": .bool(false),
        ]).confirmed()
        #expect(services.registry.perform("browserProfile.clearBrowsingData", invocation: historyOnly))
        try await Self.until { !services.cache.history.entries.contains { $0.url == page } }
        #expect(await Self.hasCookie(store))

        // Every kind (the defaults): the cookie goes too.
        let everything = ActionInvocation(target: target, arguments: ["range": .string("hour")]).confirmed()
        #expect(services.registry.perform("browserProfile.clearBrowsingData", invocation: everything))
        let deadline = ContinuousClock.now + .seconds(20)
        while await Self.hasCookie(store), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(50)) }
        #expect(!(await Self.hasCookie(store)), "the profile's cookie set in the last hour is still there")
    }

    static func hasCookie(_ store: WKWebsiteDataStore) async -> Bool {
        await store.httpCookieStore.allCookies().contains { $0.domain.hasSuffix(site) }
    }

    static func until(_ condition: () -> Bool, within timeout: Duration = .seconds(20)) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(50)) }
        try #require(condition(), "timed out")
    }
}
