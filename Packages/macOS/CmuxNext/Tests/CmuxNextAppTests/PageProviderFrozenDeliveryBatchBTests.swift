import CmuxNextActions
import CmuxNextDesign
import CmuxNextDesignTokens
import CmuxNextPages
@testable import CmuxNextSettings
import CmuxNextSettingsWindow
import CmuxNextSidebar
import CmuxNextWakeups
import Foundation
import Observation
import Testing
@testable import CmuxNextApp

/// Each stream of the Settings, Mobile Pairing, update surface and Debug Settings providers names
/// what ``PageRouter`` keeps of it while the page is hidden or frozen. A stream
/// whose event is the whole state keeps the newest (`.latest`); `cmux.settings.changed` names only
/// the keys that changed since the last event, a delta, so a drop must reach the page as a gap
/// (`.resync`, which the page answers by re-reading every row and clearing every refusal), never
/// be folded into the newest.
@MainActor @Suite struct PageProviderFrozenDeliveryBatchBTests {
    @Test func settingsChangedIsADeltaThatResyncs() async throws {
        let (page, _, directory) = try await Self.settingsPage()
        defer { try? FileManager.default.removeItem(at: directory) }
        let changed = try await Self.subscribe(page, "cmux.settings.changed")
        defer { changed.cancel() }
        #expect(changed.frozenDelivery == .resync, "a dropped settings change would lose its keys without a gap")
    }

    @Test func settingsStateStreamsKeepTheNewest() async throws {
        let (page, _, directory) = try await Self.settingsPage(hostLists: { [:] })
        defer { try? FileManager.default.removeItem(at: directory) }
        page.accountsState = { [:] }
        page.agents = AgentHarnessCenter(environment: { nil }, mainWork: MainWorkScheduler(budget: MainFrameBudget()))
        page.harnessesState = { [:] }
        page.devicesState = { [:] }
        page.devicesWatching = { _ in }
        for stream in ["cmux.settings.accounts.changed", "cmux.settings.agents.changed", "cmux.settings.harnesses.changed",
                       "cmux.settings.devices.changed", "cmux.settings.host.changed"] {
            let subscription = try await Self.subscribe(page, stream)
            defer { subscription.cancel() }
            #expect(subscription.frozenDelivery == .latest, "\(stream) carries the whole state")
        }
    }

    /// The declared policy through the real hold: two settings changes while the page is hidden
    /// reach it as one event, the newest, marked as a gap so the page re-reads every row.
    @Test func heldSettingsChangesReleaseAsOneGap() async throws {
        let (page, settings, directory) = try await Self.settingsPage()
        defer { try? FileManager.default.removeItem(at: directory) }
        let tap = EventTap(page)
        let (router, sent) = Self.router(tap)
        try await Self.subscribe(router, "cmux.settings.changed")
        router.holdDelivery()
        try await settings.set(.bool(true), at: ["history", "terminalCommands"])
        try await Self.until(tap, emitted: 1)
        try await settings.set(.number(7), at: CmuxConfigSnapshot.commandRetentionConfigPath)
        try await Self.until(tap, emitted: 2)
        #expect(sent.events.isEmpty, "nothing reaches a hidden page")
        router.releaseDelivery()
        let events = sent.events
        try #require(events.count == 1)
        #expect(events[0]["gap"]?.boolValue == true, "the dropped change's keys are lost: the page must re-read")
        let keys = events[0]["data"]?["keys"]?.arrayValue?.compactMap(\.stringValue) ?? []
        #expect(keys.contains("history.commandRetentionDays"))
        #expect(!keys.contains("history.terminalCommands"))
    }

    /// A whole-state stream through the real hold: the page gets only the newest state, no gap.
    @Test func heldHostStateReleasesOnlyTheNewest() async throws {
        let lists = HostLists()
        let (page, _, directory) = try await Self.settingsPage(hostLists: { ["n": .number(Double(lists.n))] })
        defer { try? FileManager.default.removeItem(at: directory) }
        let tap = EventTap(page)
        let (router, sent) = Self.router(tap)
        try await Self.subscribe(router, "cmux.settings.host.changed")
        router.holdDelivery()
        lists.n = 1
        try await Self.until(tap, emitted: 1)
        lists.n = 2
        try await Self.until(tap, emitted: 2)
        router.releaseDelivery()
        let events = sent.events
        try #require(events.count == 1)
        #expect(events[0]["data"]?["n"]?.doubleValue == 2)
        #expect(events[0]["gap"] == nil, "a state stream needs no re-read")
    }

    @Test func mobilePairingChangesKeepTheNewest() async throws {
        let services = AppServices(environment: AppEnvironment.current([:]))
        let page = MobilePairingPageProvider(services: services)
        let changes = try await Self.subscribe(page, MobilePairingPageProvider.changesStream)
        defer { changes.cancel() }
        #expect(changes.frozenDelivery == .latest)
    }

    @Test func updateSurfaceChangesKeepTheNewest() async throws {
        let page = UpdateSurfaceProvider(kind: .updated, services: nil, mainWork: linklessMainWork())
        let changes = try await Self.subscribe(page, "cmux.changelog.surface.changes")
        defer { changes.cancel() }
        #expect(changes.frozenDelivery == .latest)
    }

    @Test func debugTunablesChangedKeepsTheNewest() async throws {
        let page = DebugSettingsPageProvider(model: DebugSettingsModel(store: TunableStore(), descriptors: []), hangs: nil, on: linklessMainWork())
        let changed = try await Self.subscribe(page, "cmux.debug.tunables.changed")
        defer { changed.cancel() }
        #expect(changed.frozenDelivery == .latest)
    }

    /// Envelopes the router sent to the page; `events` unpacks a release batch (`evs`) in order.
    final class Sent {
        var envelopes: [JSONValue] = []
        var events: [JSONValue] {
            envelopes.flatMap { envelope -> [JSONValue] in
                switch envelope["t"]?.stringValue {
                case "ev": [envelope]
                case "evs": envelope["events"]?.arrayValue ?? []
                default: []
                }
            }
        }
    }

    /// The provider under test, counting each event it emits before the router's hold sees it.
    @MainActor @Observable final class EventTap: PageProvider {
        @ObservationIgnored let inner: any PageProvider
        private(set) var emitted = 0

        init(_ inner: any PageProvider) { self.inner = inner }

        func call(_ op: String, params: JSONValue, context: PageCallContext) async throws -> JSONValue {
            try await inner.call(op, params: params, context: context)
        }

        func subscribe(_ stream: String, filter: JSONValue, context: PageCallContext,
                       onEvent: @escaping @MainActor (JSONValue) -> Void) async throws -> PageSubscription {
            try await inner.subscribe(stream, filter: filter, context: context) { [weak self] data in
                self?.emitted += 1
                onEvent(data)
            }
        }

        func eventDeliveryDropped(stream: String, data: JSONValue, publicationID: UInt64?) {
            inner.eventDeliveryDropped(stream: stream, data: data, publicationID: publicationID)
        }
    }

    /// The live lists the Settings page shows beside its rows, as an observable test value.
    @MainActor @Observable final class HostLists {
        var n = 0
    }

    private static func router(_ provider: any PageProvider) -> (PageRouter, Sent) {
        let descriptor = PageDescriptor(id: "cmux.settings-held-test", resource: "settings", processGroup: .solo,
                                        namespaces: ["cmux.settings."])
        let router = PageRouter(descriptor: descriptor, routes: [PageRoute(prefix: "cmux.settings.", provider: provider)])
        let sent = Sent()
        router.send = { envelope in sent.envelopes.append(envelope) }
        return (router, sent)
    }

    private static func subscribe(_ router: PageRouter, _ stream: String) async throws {
        let reply = await router.handle(["t": "sub", "id": 1, "stream": .string(stream)])
        try #require(reply["t"]?.stringValue == "ok", "\(reply)")
    }

    private static func until(_ tap: EventTap, emitted count: Int) async throws {
        await ObservationDeadline(owner: "PageProviderFrozenDeliveryBatchBTests").until({ tap.emitted >= count }, limit: .seconds(10))
        try #require(tap.emitted == count, "the provider emitted \(tap.emitted) events, expected \(count)")
    }

    private static func subscribe(_ page: any PageProvider, _ stream: String) async throws -> PageSubscription {
        try await page.subscribe(stream, filter: [:], context: PageCallContext(page: "cmux.test"), onEvent: { _ in })
    }

    private static func settingsPage(hostLists: (@MainActor () -> JSONValue)? = nil) async throws
        -> (SettingsPageProvider, SettingsController, URL) {
        let directory = FileManager.default.temporaryDirectory.appending(path: "cn-frozen-delivery-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "cmux.json")
        try Data("{}".utf8).write(to: url)
        let settings = SettingsController(registry: ActionRegistry(catalog: []), design: DesignSettings(), fileURL: url,
            managedReader: FixedManagedPreferenceReader(ManagedPreferences()), managedWatchFiles: [])
        await settings.reload()
        return (SettingsPageProvider(settings: settings, hostLists: hostLists, on: linklessMainWork()), settings, directory)
    }
}
