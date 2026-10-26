@testable import CmuxNextDiff
import CmuxNextPages
import CmuxNextSettings
import Foundation
import Testing

/// The diff tab's streams declare what a frozen page keeps (p13-webui-027): sidecar events answer
/// the page's requests and are never dropped (`.ordered`); the prefs stream sends the whole value,
/// so only the newest is kept (`.latest`).
@MainActor
@Suite struct DiffPageProviderFrozenDeliveryTests {
    final class FixedPrefs: DiffPrefsStoring {
        func prefs() -> [String: JSONValue] { [:] }
        func setPref(_ key: String, to value: JSONValue) async throws {}
        func listen(_ onPrefs: @escaping @MainActor ([String: JSONValue]) -> Void) -> () -> Void { {} }
    }

    private static let context = PageCallContext(page: "cmux.diff")

    @Test func sidecarEventsAreOrdered() async throws {
        let provider = DiffPageProvider(ready: nil, sidecar: nil, languages: nil)
        let subscription = try await provider.subscribe(DiffPageProvider.eventsStream, filter: .object([:]),
                                                        context: Self.context) { _ in }
        #expect(subscription.frozenDelivery == .ordered)
        subscription.cancel()
    }

    @Test func prefsKeepTheNewest() async throws {
        let viewed = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiffFrozenDelivery-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: viewed) }
        let stores = DiffPageStores(prefs: FixedPrefs(), viewed: DiffViewedFiles(url: viewed))
        let provider = DiffPageProvider(ready: nil, sidecar: nil, languages: nil, stores: stores)
        let subscription = try await provider.subscribe(DiffPageProvider.prefsStream, filter: .object([:]),
                                                        context: Self.context) { _ in }
        #expect(subscription.frozenDelivery == .latest)
        subscription.cancel()
    }
}
