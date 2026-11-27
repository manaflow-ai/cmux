import CmuxSettings
import Foundation
import Testing

@testable import CmuxSettingsUI

@MainActor
@Suite
struct DefaultsValueModelObservationStartupTests {
    private typealias DefaultsEvent<Value: SettingCodable> = UserDefaultsSettingsValueEvent<Value>

    @Test func startObservingIncludesPendingWritesCreatedBeforeStreamCreation() async {
        let store = UserDefaultsSettingsStore(
            defaults: UserDefaults(suiteName: "defaults-value-model-startup-\(UUID().uuidString)")!
        )
        let key = SettingCatalog().betaFeatures.extensions
        let capture = DefaultsValueModelSourceCapture()
        let (stream, _) = AsyncStream<DefaultsEvent<Bool>>.makeStream()
        let model = DefaultsValueModel(
            store: store,
            key: key,
            makeStream: { sources in
                capture.sources = sources
                return stream
            }
        )

        model.startObserving()
        let source = model.set(true)
        await waitUntil { capture.sources != nil }

        #expect(capture.sources?.contains(source) == true)
    }

    private func waitUntil(_ condition: () -> Bool) async {
        var spins = 0
        while !condition(), spins < 100_000 {
            await Task.yield()
            spins += 1
        }
    }
}

@MainActor
private final class DefaultsValueModelSourceCapture {
    var sources: Set<UserDefaultsSettingsMutationSource>?
}
