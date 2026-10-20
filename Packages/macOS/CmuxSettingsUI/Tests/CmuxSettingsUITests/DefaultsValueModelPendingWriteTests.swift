import CmuxSettings
import Foundation
import Testing

@testable import CmuxSettingsUI

@MainActor
@Suite
struct DefaultsValueModelPendingWriteTests {
    private typealias DefaultsEvent<Value: SettingCodable> = UserDefaultsSettingsValueEvent<Value>

    @Test func observedExternalValueDoesNotCancelQueuedLocalWrite() async {
        let suiteName = "defaults-value-model-pending-write-\(UUID().uuidString)"
        let store = UserDefaultsSettingsStore(defaults: UserDefaults(suiteName: suiteName)!)
        let key = SettingCatalog().betaFeatures.extensions
        let (stream, continuation) = AsyncStream<DefaultsEvent<Bool>>.makeStream()
        let model = DefaultsValueModel(
            store: store,
            key: key,
            makeStream: { _ in stream }
        )
        model.startObserving()

        _ = model.set(true)
        continuation.yield(event(false))

        let storedValue = await waitForStoreValue(true, store: store, key: key)

        #expect(storedValue == true)
    }

    private func event<Value: SettingCodable>(_ value: Value) -> DefaultsEvent<Value> {
        DefaultsEvent(value: value)
    }

    private func waitForStoreValue<Value: SettingCodable>(
        _ expectedValue: Value,
        store: UserDefaultsSettingsStore,
        key: DefaultsKey<Value>
    ) async -> Value {
        var current = await store.value(for: key)
        var spins = 0
        while current != expectedValue, spins < 100_000 {
            await Task.yield()
            current = await store.value(for: key)
            spins += 1
        }
        return current
    }
}
