import AppKit
@testable import CmuxNextApp
import CmuxNextBrowser
import CmuxNextHistory
@testable import CmuxNextHistoryPages
import CmuxNextPages
import CmuxNextSettings
import Foundation
import Testing

/// cmux#37302 review: the History page's remove, site remove and clear go through the app's own
/// History path (HistoryService, as the native page called it), not straight to the daemon, so the
/// omnibar's suggestions forget what the page removed.
@MainActor @Suite(.serialized) struct HistoryPageChangesTests {
    /// The daemon relay: records what reaches it.
    final class Relay: PageProvider {
        var sent: [String] = []
        func call(_ op: String, params: JSONValue, context: PageCallContext) async throws -> JSONValue {
            sent.append(op)
            return .object([:])
        }
    }

    struct World {
        let services: AppServices
        let provider: HistoryCookieBackupsPageProvider
        let relay: Relay
        var suggestions: InMemoryBrowserHistory { services.cache.history }
    }

    /// The History page's provider wired as PageFactory wires it (the app's HistoryService), over the default profile's
    /// omnibar history with `urls` visited (no daemon: the app's own log).
    static func world(_ urls: [String]) async throws -> World {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        services.history.attach(services.cache.history, profile: .default)
        for (index, url) in urls.enumerated() {
            services.cache.history.recordVisit(url: try #require(URL(string: url)), title: "Page \(index)", at: Date().addingTimeInterval(Double(-index)))
        }
        _ = await services.history.flushLocalHistory(profile: .default)
        let provider = HistoryCookieBackupsPageProvider { nil }
        let relay = Relay()
        provider.relay = relay
        provider.history = services.history
        return World(services: services, provider: provider, relay: relay)
    }

    static func click(_ at: TimeInterval) -> PageCallContext {
        PageCallContext(page: "cmux.history", userGesture: true, gestureEvent: at)
    }

    static func suggested(_ world: World) -> Set<String> {
        Set(world.suggestions.entries.map(\.url.absoluteString))
    }

    @Test func aRemovedPageLeavesTheSuggestions() async throws {
        let world = try await Self.world(["https://a.example/one", "https://b.example/two"])
        #expect(Self.suggested(world) == ["https://a.example/one", "https://b.example/two"])
        let entries = await world.services.history.entries(HistoryQuery(kinds: [.page]))
        let entry = try #require(entries.first { $0.detail == "https://a.example/one" })
        _ = try await world.provider.call("cmux.history.entries.remove", params: ["ids": .array([.string(entry.id)])], context: Self.click(1))
        #expect(Self.suggested(world) == ["https://b.example/two"])
        #expect(world.relay.sent.isEmpty, "the remove skipped the app's History path")
    }

    @Test func aRemovedSiteLeavesTheSuggestions() async throws {
        let world = try await Self.world(["https://c.example/1", "https://c.example/2", "https://d.example/3"])
        _ = try await world.provider.call("cmux.history.site.remove", params: ["host": "c.example"], context: Self.click(2))
        #expect(Self.suggested(world) == ["https://d.example/3"])
        #expect(world.relay.sent.isEmpty)
    }

    @Test func aClearLeavesNoSuggestions() async throws {
        let world = try await Self.world(["https://e.example/1", "https://f.example/2"])
        _ = try await world.provider.call("cmux.history.clear", params: ["range": "all", "kinds": .array([.string("page")])], context: Self.click(3))
        #expect(Self.suggested(world).isEmpty)
        #expect(world.relay.sent.isEmpty)
    }

    /// The click checks stay: no click, nothing changes and nothing is sent.
    @Test func withoutAClickNothingIsRemoved() async throws {
        let world = try await Self.world(["https://g.example/1"])
        for (op, params) in [("cmux.history.site.remove", ["host": "g.example"] as JSONValue), ("cmux.history.clear", ["range": "all"] as JSONValue)] {
            await #expect(throws: PageError.self) {
                try await world.provider.call(op, params: params, context: PageCallContext(page: "cmux.history"))
            }
        }
        #expect(Self.suggested(world) == ["https://g.example/1"])
        #expect(world.relay.sent.isEmpty)
    }
}
