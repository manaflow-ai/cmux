import CmuxNextActions
import CmuxNextDesign
import CmuxNextDesignTokens
import CmuxNextPages
@testable import CmuxNextSettings
import CmuxNextSettingsWindow
import CmuxNextSidebar
import Foundation
import Testing
@testable import CmuxNextApp

/// Each stream of the Settings, Mobile Pairing, update surface and Debug Settings providers names
/// what ``PageRouter`` keeps of it while the page is hidden or frozen (p13-webui-025). A stream
/// whose event is the whole state keeps the newest (`.latest`); `cmux.settings.changed` names only
/// the keys that changed since the last event, a delta, so a drop must reach the page as a gap
/// (`.resync`), never be folded into the newest.
@MainActor @Suite struct PageProviderFrozenDeliveryBatchBTests {
    @Test func settingsChangedIsADeltaThatResyncs() async throws {
        let (page, directory) = try await Self.settingsPage()
        defer { try? FileManager.default.removeItem(at: directory) }
        let changed = try await Self.subscribe(page, "cmux.settings.changed")
        defer { changed.cancel() }
        #expect(changed.frozenDelivery == .resync, "a dropped settings change would lose its keys without a gap")
    }

    @Test func settingsStateStreamsKeepTheNewest() async throws {
        let (page, directory) = try await Self.settingsPage(hostLists: { [:] })
        defer { try? FileManager.default.removeItem(at: directory) }
        page.accountsState = { [:] }
        page.harnessesState = { [:] }
        page.devicesState = { [:] }
        page.devicesWatching = { _ in }
        for stream in ["cmux.settings.accounts.changed", "cmux.settings.harnesses.changed",
                       "cmux.settings.devices.changed", "cmux.settings.host.changed"] {
            let subscription = try await Self.subscribe(page, stream)
            defer { subscription.cancel() }
            #expect(subscription.frozenDelivery == .latest, "\(stream) carries the whole state")
        }
    }

    @Test func mobilePairingChangesKeepTheNewest() async throws {
        let services = AppServices(environment: AppEnvironment.current([:]))
        let page = MobilePairingPageProvider(services: services)
        let changes = try await Self.subscribe(page, MobilePairingPageProvider.changesStream)
        defer { changes.cancel() }
        #expect(changes.frozenDelivery == .latest)
    }

    @Test func updateSurfaceChangesKeepTheNewest() async throws {
        let page = UpdateSurfaceProvider(kind: .updated, services: nil)
        let changes = try await Self.subscribe(page, "cmux.changelog.surface.changes")
        defer { changes.cancel() }
        #expect(changes.frozenDelivery == .latest)
    }

    @Test func debugTunablesChangedKeepsTheNewest() async throws {
        let page = DebugSettingsPageProvider(model: DebugSettingsModel(store: TunableStore(), descriptors: []), hangs: nil)
        let changed = try await Self.subscribe(page, "cmux.debug.tunables.changed")
        defer { changed.cancel() }
        #expect(changed.frozenDelivery == .latest)
    }

    private static func subscribe(_ page: any PageProvider, _ stream: String) async throws -> PageSubscription {
        try await page.subscribe(stream, filter: [:], context: PageCallContext(page: "cmux.test"), onEvent: { _ in })
    }

    private static func settingsPage(hostLists: (@MainActor () -> JSONValue)? = nil) async throws -> (SettingsPageProvider, URL) {
        let directory = FileManager.default.temporaryDirectory.appending(path: "cn-frozen-delivery-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "cmux.json")
        try Data("{}".utf8).write(to: url)
        let settings = SettingsController(registry: ActionRegistry(catalog: []), design: DesignSettings(), fileURL: url,
            managedReader: FixedManagedPreferenceReader(ManagedPreferences()), managedWatchFiles: [])
        await settings.reload()
        return (SettingsPageProvider(settings: settings, hostLists: hostLists), directory)
    }
}
