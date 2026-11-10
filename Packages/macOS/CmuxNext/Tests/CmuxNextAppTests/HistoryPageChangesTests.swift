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

    /// cmux#37302 review: an older visit, past the 5,000-row window `entry(id:)` searches, that a
    /// page shows as a search hit can be removed and opened from that page, even after another
    /// History page listed another query: each page keeps the rows it showed.
    @Test func anOlderSearchHitCanBeRemovedAndOpened() async throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let history = services.cache.history
        services.history.attach(history, profile: .default)
        let start = Date().addingTimeInterval(-86_400)
        history.recordVisit(url: try #require(URL(string: "https://old.example/target")), title: "Old target", at: start)
        for batch in 0..<3 {
            for index in 0..<1_700 {
                let n = batch * 1_700 + index
                history.recordVisit(url: try #require(URL(string: "https://new.example/\(n)")), title: "New \(n)", at: start.addingTimeInterval(Double(n + 1)))
            }
            _ = await services.history.flushLocalHistory(profile: .default)
        }
        let hit = try #require(await services.history.read(HistoryQuery(text: "old.example", kinds: [.page])).entries.first)
        #expect(await services.history.entry(id: hit.id) == nil, "the id window no longer misses the older visit; this test shows nothing")

        // Two History pages, wired as PageFactory wires them: A searches the old visit, then B lists another query.
        func page() -> HistoryCookieBackupsPageProvider {
            let provider = HistoryCookieBackupsPageProvider { nil }
            provider.relay = Relay()
            provider.history = services.history
            services.history.pages.add(provider)
            return provider
        }
        let pageA = page(), pageB = page()
        let listed = try await pageA.call("cmux.history.entries.list", params: ["text": "old.example", "kinds": .array([.string("page")])],
                                          context: PageCallContext(page: "cmux.history"))
        let rows = try #require(listed["entries"]?.arrayValue)
        #expect(rows.compactMap { $0["id"]?.stringValue } == [hit.id])
        _ = try await pageB.call("cmux.history.entries.list", params: ["text": "new.example/5", "kinds": .array([.string("page")])],
                                 context: PageCallContext(page: "cmux.history"))
        #expect(pageB.shown[hit.id] == nil)
        // A's Open (`history.open` resolves through `entry(id:)`) and A's remove both find the row A shows.
        #expect(await services.history.entry(id: hit.id)?.id == hit.id)
        _ = try await pageA.call("cmux.history.entries.remove", params: ["ids": .array([.string(hit.id)])], context: Self.click(9))
        #expect(!history.entries.contains { $0.url.absoluteString == "https://old.example/target" })
        let after = await services.history.read(HistoryQuery(text: "old.example", kinds: [.page])).entries
        #expect(after.isEmpty, "the remove left the visit in the log")
    }

    /// The app's read model behind the page's list (as the native page showed it).
    final class ReadModel: HistoryPageEditing {
        var entries: [HistoryEntry] = []
        var queries: [HistoryQuery] = []
        func read(_ query: HistoryQuery) async -> HistoryRead {
            queries.append(query)
            return HistoryRead(entries: entries)
        }
        func entry(id: String) async -> HistoryEntry? { entries.first { $0.id == id } }
        func remove(_ entry: HistoryEntry) {}
        func removePages(host: String) {}
        func clear(kinds: Set<HistoryEntry.Kind>, range: HistoryRange) {}
    }

    /// cmux#37302 review: the page's list is the app's read model, not the local daemon's rows: another
    /// machine's command rows are in it, and a location whose tab is unreachable shows unavailable.
    @Test func theListIsTheAppsReadModel() async throws {
        let model = ReadModel()
        let now = Date()
        let command = TerminalCommand(id: 7, machine: "build-box", terminal: "t1", command: "make test", cwd: "/src", exitCode: 0,
                                      startedAt: now, duration: 1)
        let location = HistoryLocation(key: .init(machine: "laptop", tab: "tab-1"), window: "w", workspace: "ws", pane: "p",
                                       content: .terminal, title: "shell", workspaceTitle: "Work", machineName: "laptop")
        model.entries = [
            HistoryEntry(id: "command:build-box/7", kind: .command, time: now, title: "make test", detail: "/src", machineName: "build-box",
                         payload: .command(command)),
            HistoryEntry(id: "location:laptop:tab-1:0", kind: .location, time: now.addingTimeInterval(-1), title: "shell", detail: "Work",
                         machineName: "laptop", isAvailable: false, payload: .location(location, isCurrent: false)),
        ]
        let provider = HistoryCookieBackupsPageProvider { nil }
        let relay = Relay()
        provider.relay = relay
        provider.history = model
        let listed = try await provider.call("cmux.history.entries.list",
                                             params: ["kinds": .array([.string("command"), .string("location")]), "text": "", "limit": .number(1_000)],
                                             context: PageCallContext(page: "cmux.history"))
        let rows = try #require(listed["entries"]?.arrayValue)
        #expect(relay.sent.isEmpty, "the list went straight to the local daemon")
        #expect(model.queries.first?.kinds == [.command, .location])
        #expect(rows.first?["machine"]?.stringValue == "build-box")
        #expect(rows.first?["command"]?.stringValue == "make test")
        #expect(rows.last?["kind"]?.stringValue == "location")
        #expect(rows.last?["available"] == .bool(false))
    }
}
