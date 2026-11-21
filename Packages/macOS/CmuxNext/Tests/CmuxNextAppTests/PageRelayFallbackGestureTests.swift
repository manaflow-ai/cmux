import AppKit
@testable import CmuxNextApp
@testable import CmuxNextDaemon
@testable import CmuxNextHistoryPages
import CmuxNextPages
import Foundation
import Testing

/// cmux#37302 review: against a daemon without `origin-claim-v1` page calls go on the main
/// connection, which the daemon takes as the person's own with no page allow list. The app then
/// applies its copy of the page's spec (``PageOperations``): reads go through, a `gesture`
/// mutation only on the person's own key or pointer event (one call per event), a `confirm` one
/// only after a sheet, and anything the page's spec does not list never.
@MainActor @Suite(.serialized) struct PageRelayFallbackGestureTests {
    /// How a call ended: refused for the missing origin claim, or let through to the main
    /// connection (none in this test, so `notConnected`: the call got past the spec check).
    private enum Outcome { case refused, forwarded, other }

    /// A page's channel on a daemon without `origin-claim-v1` and no live connection.
    private static func channel(_ page: String = "cmux.history") throws -> PageRelayChannel {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let json = #"{"app":"cmux-tui","protocol":1,"session":"relay-fallback","generation":"g1","capabilities":["v2"]}"#
        services.machines.local.store.noteHandshake(try JSONDecoder().decode(DaemonIdentity.self, from: Data(json.utf8)))
        #expect(!services.machines.local.supports(DaemonClientRole.originClaimCapability))
        #expect(services.machines.local.connection == nil)
        return PageRelayChannel(service: services.machines.local, page: PageRelayChannel.relayPageID(page))
    }

    private static func outcome(_ channel: PageRelayChannel, _ operation: String, _ context: PageCallContext,
                                params: [String: CmuxNextDaemon.JSONValue] = [:]) async -> Outcome {
        do {
            _ = try await channel.send(operation: operation, params: params, idempotencyKey: "k", context: context)
            return .other
        } catch DaemonError.missingCapabilities(let missing) where missing == [DaemonClientRole.originClaimCapability] {
            return .refused
        } catch DaemonError.notConnected {
            return .forwarded
        } catch {
            return .other
        }
    }

    @Test func readsGoThroughWithoutAGestureAndMutationsAreRefused() async throws {
        let history = try Self.channel()
        let page = PageCallContext(page: "cmux.history")
        for read in ["history.entries.list", "history.visit.summaries"] {
            #expect(await Self.outcome(history, read, page) == .forwarded, "\(read)")
        }
        for mutation in ["history.clear", "history.entries.remove", "history.site.remove"] {
            #expect(await Self.outcome(history, mutation, page) == .refused, "\(mutation)")
        }
        // A gesture flag with no event behind it is not the person's.
        #expect(await Self.outcome(history, "history.clear", PageCallContext(page: "cmux.history", userGesture: true)) == .refused)
        let stash = try Self.channel("cmux.stash")
        #expect(await Self.outcome(stash, "stash.list", PageCallContext(page: "cmux.stash")) == .forwarded)
        #expect(await Self.outcome(stash, "stash.import", PageCallContext(page: "cmux.stash")) == .refused)
    }

    @Test func aMutationGoesOnThePersonsGestureOncePerEvent() async throws {
        let channel = try Self.channel()
        let click = PageCallContext(page: "cmux.history", userGesture: true, gestureEvent: 42)
        #expect(await Self.outcome(channel, "history.clear", click) == .forwarded)
        // A second call off the same event is refused; a new event backs a new call, a sheet does too.
        #expect(await Self.outcome(channel, "history.entries.remove", click) == .refused)
        let next = PageCallContext(page: "cmux.history", userGesture: true, gestureEvent: 43)
        #expect(await Self.outcome(channel, "history.site.remove", next) == .forwarded)
        let sheet = PageCallContext(page: "cmux.history", origin: "user", confirmed: true)
        #expect(await Self.outcome(channel, "history.entries.remove", sheet) == .forwarded)
    }

    /// cmux#37378 review: the Feed's Mark All Read is one `feed.intent` of every shown id, so one
    /// click backs it however long the Inbox is; a second intent off the same click (a page-side
    /// batch loop) would be refused, which is why the daemon, not the page, splits it per owner.
    @Test func oneClickBacksOneReadIntentOfEveryShownItem() async throws {
        let feed = try Self.channel("cmux.feed")
        let ids = (0..<300).map { CmuxNextDaemon.JSONValue.string("fi_\($0)") }
        let read: [String: CmuxNextDaemon.JSONValue] = ["kind": .string("read"), "items": .array(ids)]
        let click = PageCallContext(page: "cmux.feed", userGesture: true, gestureEvent: 300)
        #expect(await Self.outcome(feed, "feed.intent", click, params: read) == .forwarded)
        #expect(await Self.outcome(feed, "feed.intent", click, params: read) == .refused)
    }

    @Test func anOpThePagesSpecDoesNotListIsRefusedEvenOnAGestureOrSheet() async throws {
        let channel = try Self.channel()
        let click = PageCallContext(page: "cmux.history", userGesture: true, gestureEvent: 7)
        let sheet = PageCallContext(page: "cmux.history", origin: "user", confirmed: true)
        for operation in ["stash.import", "workspace.close", "apps.install"] {
            #expect(await Self.outcome(channel, operation, click) == .refused, "\(operation)")
            #expect(await Self.outcome(channel, operation, sheet) == .refused, "\(operation)")
        }
        // A `confirm` op of a page that has one needs the sheet; a click is not enough.
        let apps = try Self.channel("cmux.apps")
        #expect(await Self.outcome(apps, "apps.install", PageCallContext(page: "cmux.apps", userGesture: true, gestureEvent: 8)) == .refused)
        #expect(await Self.outcome(apps, "apps.install", PageCallContext(page: "cmux.apps", origin: "user", confirmed: true)) == .forwarded)
    }

    /// A change subscription never needs a gesture: on this daemon the page has no live events
    /// (no relay connection: ``PageRelayChannel/NoSuchEvent`` connected, `notConnected` here; the
    /// page then reads without them), never the spec refusal.
    @Test func aSubscribeIsNeverRefusedForAGesture() async throws {
        let channel = try Self.channel()
        do {
            _ = try await channel.listen(event: "history-changed") { _ in }
            Issue.record("a fallback listen answered a stream")
        } catch is PageRelayChannel.NoSuchEvent {
        } catch DaemonError.notConnected {
        } catch {
            Issue.record("a fallback listen failed with \(error)")
        }
    }

    /// ``PageOperations/spec`` and the History provider's gesture list are copies of
    /// cmux-tui/spec/page-router.json; a change there must change them too.
    @Test func theAppsCopyMatchesThePageRouterSpec() throws {
        var root = URL(fileURLWithPath: #filePath)
        while !FileManager.default.fileExists(atPath: root.appendingPathComponent("cmux-tui/spec").path) {
            let parent = root.deletingLastPathComponent()
            try #require(parent.path != root.path, "no cmux-tui/spec above \(#filePath)")
            root = parent
        }
        let data = try Data(contentsOf: root.appendingPathComponent("cmux-tui/spec/page-router.json"))
        let spec = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let pages = try #require(spec["pages"] as? [String: [String: Any]])
        var copied: [String: PageOperations] = [:]
        for (page, entry) in pages {
            func list(_ key: String) -> Set<String> { Set(entry[key] as? [String] ?? []) }
            copied[page] = PageOperations(read: list("read"), gesture: list("gesture"), confirm: list("confirm"))
        }
        #expect(copied == PageOperations.spec)
        let history = try #require(PageOperations.spec["history"])
        #expect(Set(history.gesture.map { "cmux." + $0 }) == HistoryCookieBackupsPageProvider.gestureOperations)
    }
}
