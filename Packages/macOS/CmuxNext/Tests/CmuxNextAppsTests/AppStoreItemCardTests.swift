@testable import CmuxNextApps
import CmuxNextDesign
import Testing

/// The App Store's item card (Leo, 2026-10-22: "we should also have nicer primitives for the app
/// store"): one card for features and apps, drawn in the `apps.store.cardStyle` look.
@MainActor @Suite struct AppStoreItemCardTests {
    /// The tunable is in Debug Settings and defaults to the store's original card, so nothing
    /// changes until someone picks another look.
    @Test func theCardLookIsATunableThatDefaultsToTheOriginalCard() {
        #expect(AppsTunables.cardLook.key == "apps.store.cardStyle")
        #expect(AppsTunables.cardLook.defaultValue == .compact)
        #expect(AppsTunables.all.map(\.key).contains("apps.store.cardStyle"))
        #expect(Set(AppsTunables.all.map(\.key)).count == AppsTunables.all.count, "tunable keys are unique")
        #expect(AppStoreCardLook.allCases.count == 3, "three looks to pick from")
        #expect(Set(AppStoreCardLook.allCases.map(\.tunableTitle)).count == 3)
    }

    /// A demo or screenshot pins a look without touching the tunable.
    @Test func theModelFollowsItsOverrideElseTheTunable() {
        let model = AppStoreModel(client: AppsClient(transport: OfflineStoreAppsTransport()))
        #expect(model.cardLook == AppsTunables.cardLook.value)
        for look in AppStoreCardLook.allCases {
            model.cardLookOverride = look
            #expect(model.cardLook == look)
        }
        model.cardLookOverride = nil
        #expect(model.cardLook == AppsTunables.cardLook.value)
    }

    /// The compact grid keeps the store's original column width; the wider looks need more room
    /// (a row holds its actions at the end).
    @Test func eachLookHasItsGridWidth() {
        #expect(AppStoreCardLook.compact.minimumCardWidth == AppStoreCardStyle.minimumWidth)
        #expect(AppStoreCardLook.compact.minimumCardWidth < AppStoreCardLook.artwork.minimumCardWidth)
        #expect(AppStoreCardLook.artwork.minimumCardWidth < AppStoreCardLook.row.minimumCardWidth)
    }
}

/// An app supervisor that is never reachable (the store's pages do not need one).
final class OfflineStoreAppsTransport: AppsTransport {
    var availability: AppsAvailability { .unavailable(.notConnected) }
    var onEvent: ((AppsTransportEvent) -> Void)?
    private static var offline: AppsTransportError { AppsTransportError(message: "offline", connectionLost: true) }

    func start() {}
    func list() async throws(AppsTransportError) -> AppsListReply { throw Self.offline }
    func set(app: String, change: AppChange, origin: AppOrigin, idempotencyKey: String) async throws(AppsTransportError) -> AppRecord {
        throw Self.offline
    }
    func mount(app: String, interface: String, mountID: String, context: AppJSON) async throws(AppsTransportError) { throw Self.offline }
    func unmount(mountID: String) async throws(AppsTransportError) { throw Self.offline }
    func dispatch(mountID: String, node: String, event: String, payload: AppJSON) async throws(AppsTransportError) { throw Self.offline }
    func run(app: String, op: String, args: AppJSON, origin: AppOrigin, idempotencyKey: String) async throws(AppsTransportError) -> AppJSON {
        throw Self.offline
    }
    func logs(app: String, follow: Bool) async throws(AppsTransportError) -> [AppLogLine] { throw Self.offline }
}
