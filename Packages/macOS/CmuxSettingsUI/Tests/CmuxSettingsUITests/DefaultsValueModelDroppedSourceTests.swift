import CmuxSettings
import Foundation
import Testing

@testable import CmuxSettingsUI

@MainActor
@Suite struct DefaultsValueModelDroppedSourceTests {
    private typealias DefaultsEvent<Value: SettingCodable> = UserDefaultsSettingsValueEvent<Value>

    @Test func sourcedObservationWithDroppedLocalSourcesPreservesNewerPendingWrite() async {
        let store = UserDefaultsSettingsStore(
            defaults: UserDefaults(suiteName: "defaults-value-model-dropped-source-carry")!
        )
        let key = SettingCatalog().workspaceColors.selectionColorHex
        let (stream, continuation) = AsyncStream<DefaultsEvent<String>>.makeStream()
        let model = DefaultsValueModel(
            store: store,
            key: key,
            initialValue: "#000000",
            makeStream: { _ in stream }
        )
        model.startObserving()

        let firstSource = model.set("#111111")
        _ = model.set("#222222")
        #expect(model.current == "#222222")
        #expect(model.revision == 2)

        continuation.yield(
            DefaultsEvent(
                value: "#333333",
                mutationSource: UserDefaultsSettingsMutationSource(),
                supersededMutationSources: [firstSource]
            )
        )
        for _ in 0..<10 {
            await Task.yield()
        }

        #expect(model.current == "#222222")
        #expect(model.revision == 2)
    }
}
