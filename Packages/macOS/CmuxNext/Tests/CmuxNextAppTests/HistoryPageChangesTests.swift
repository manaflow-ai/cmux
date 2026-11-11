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

    /// The local daemon's read side, standing in for `history.entries.list` (the page visits are
    /// the daemon's alone): `read` answers `rows` matching the query. Everything else is the app's
    /// own HistoryService, as PageFactory wires it: `entry(id:)` (the open pages' shown rows, then the
    /// daemon) and the remove, site remove and clear that also drop the omnibar's suggestions.
    final class Daemon: HistoryPageEditing {
        let service: HistoryService
        var rows: [HistoryEntry] = []
        init(_ service: HistoryService) { self.service = service }
        func read(_ query: HistoryQuery) async -> HistoryRead { HistoryRead(entries: query.apply(to: rows)) }
        func entry(id: String) async -> HistoryEntry? { await service.entry(id: id) }
        func remove(_ entry: HistoryEntry) { service.remove(entry) }
        func removePages(host: String) { service.removePages(host: host) }
        func clear(kinds: Set<HistoryEntry.Kind>, range: HistoryRange) { service.clear(kinds: kinds, range: range) }
    }

    struct World {
        let services: AppServices
        let daemon: Daemon
        let provider: HistoryCookieBackupsPageProvider
        let relay: Relay
        var suggestions: InMemoryBrowserHistory { services.cache.history }

        /// Another History page on the same app, wired as PageFactory wires it.
        func page() -> HistoryCookieBackupsPageProvider {
            let provider = HistoryCookieBackupsPageProvider { nil }
            provider.relay = Relay()
            provider.history = daemon
            services.history.pages.add(provider)
            return provider
        }

        /// The page's list of `text` (page visits).
        @discardableResult
        func list(_ text: String, on page: HistoryCookieBackupsPageProvider? = nil) async throws -> [String] {
            let listed = try await (page ?? provider).call("cmux.history.entries.list", params: ["text": .string(text), "kinds": .array([.string("page")])],
                                                           context: PageCallContext(page: "cmux.history"))
            return (listed["entries"]?.arrayValue ?? []).compactMap { $0["id"]?.stringValue }
        }
    }

    /// The History page's provider wired as PageFactory wires it (the app's HistoryService), over the default profile's
    /// omnibar history with `urls` visited, which the daemon stand-in lists.
    static func world(_ urls: [String]) async throws -> World {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        services.history.attach(services.cache.history, profile: .default)
        let daemon = Daemon(services.history)
        for (index, url) in urls.enumerated() {
            let at = Date().addingTimeInterval(Double(-index))
            services.cache.history.recordVisit(url: try #require(URL(string: url)), title: "Page \(index)", at: at)
            daemon.rows.append(HistoryEntry(id: "page:default:\(index + 1)", kind: .page, time: at, title: "Page \(index)", detail: url,
                                            payload: .page(url: url, profile: "default")))
        }
        let provider = HistoryCookieBackupsPageProvider { nil }
        let relay = Relay()
        provider.relay = relay
        provider.history = daemon
        services.history.pages.add(provider)
        return World(services: services, daemon: daemon, provider: provider, relay: relay)
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
        let id = try #require(try await world.list("a.example").first)
        _ = try await world.provider.call("cmux.history.entries.remove", params: ["ids": .array([.string(id)])], context: Self.click(1))
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

    /// cmux#37302 review: a search hit the daemon's by-id lookup no longer finds (an older visit,
    /// past its 5,000-row window) can be removed and opened from the page that shows it, even after
    /// another History page listed another query: each page keeps the rows it showed.
    @Test func anOlderSearchHitCanBeRemovedAndOpened() async throws {
        let world = try await Self.world(["https://old.example/target", "https://new.example/1", "https://new.example/2"])
        let pageA = world.provider, pageB = world.page()
        let hit = try #require(try await world.list("old.example", on: pageA).first)
        #expect(try await world.list("new.example", on: pageB).count == 2)
        #expect(pageB.shown[hit] == nil)
        // A's Open (`history.open` resolves through `entry(id:)`) and A's remove both find the row A shows.
        #expect(await world.services.history.entry(id: hit)?.detail == "https://old.example/target")
        _ = try await pageA.call("cmux.history.entries.remove", params: ["ids": .array([.string(hit)])], context: Self.click(9))
        #expect(!Self.suggested(world).contains("https://old.example/target"))
        #expect(Self.suggested(world).contains("https://new.example/1"))
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
