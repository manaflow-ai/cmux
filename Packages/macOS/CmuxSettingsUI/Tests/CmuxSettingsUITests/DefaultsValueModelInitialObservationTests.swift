import CmuxSettings
import Foundation
import Testing

@testable import CmuxSettingsUI

@MainActor
@Suite struct DefaultsValueModelInitialObservationTests {
    private typealias DefaultsEvent<Value: SettingCodable> = UserDefaultsSettingsValueEvent<Value>

    private func event<Value: SettingCodable>(
        _ value: Value,
        source: UserDefaultsSettingsMutationSource? = nil,
        supersededSource: UserDefaultsSettingsMutationSource? = nil,
        isInitialSnapshot: Bool = false
    ) -> DefaultsEvent<Value> {
        DefaultsEvent(
            value: value,
            mutationSource: source,
            supersededMutationSource: supersededSource,
            isInitialSnapshot: isInitialSnapshot
        )
    }

    @Test func staleInitialObservationDoesNotConsumePendingLocalEcho() async {
        let (model, continuation) = makeModel()
        let source = model.set("#111111")
        model.startObserving()

        continuation.yield(event("#000000", isInitialSnapshot: true))
        for _ in 0..<10 {
            await Task.yield()
        }

        #expect(model.current == "#111111")
        #expect(model.revision == 1)
        continuation.yield(event("#111111", source: source))
        for _ in 0..<10 {
            await Task.yield()
        }

        #expect(model.current == "#111111")
        #expect(model.revision == 1)
    }

    @Test func initialExternalObservationWhilePendingLocalWriteUpdatesCurrent() async {
        let (model, continuation) = makeModel()
        _ = model.set("#111111")
        model.startObserving()

        continuation.yield(event("#222222"))
        await waitUntil { model.current == "#222222" }

        #expect(model.current == "#222222")
        #expect(model.revision == 2)
    }

    @Test func initialRestoredValueAfterPendingLocalWriteUpdatesCurrent() async {
        let (model, continuation) = makeModel()
        let source = model.set("#111111")
        model.startObserving()

        continuation.yield(event("#000000", supersededSource: source))
        await waitUntil { model.current == "#000000" }

        #expect(model.current == "#000000")
        #expect(model.revision == 2)
    }

    @Test func initialSourceLessUpdateMatchingInitialValueAfterPendingLocalWriteUpdatesCurrent() async {
        let (model, continuation) = makeModel()
        _ = model.set("#111111")
        model.startObserving()

        continuation.yield(event("#000000"))
        await waitUntil { model.current == "#000000" }

        #expect(model.current == "#000000")
        #expect(model.revision == 2)
    }

    @Test func sourceLessStoreWriteRestoringInitialValueAfterPendingLocalWriteUpdatesCurrent() async {
        let store = UserDefaultsSettingsStore(
            defaults: UserDefaults(suiteName: "defaults-value-model-source-less-restore-\(UUID().uuidString)")!
        )
        let key = SettingCatalog().workspaceColors.selectionColorHex
        let model = DefaultsValueModel(store: store, key: key)

        await withCheckedContinuation { continuation in
            model.set("#111111") {
                continuation.resume()
            }
        }
        await store.set("", for: key)
        model.startObserving()

        await waitUntil { model.current == "" }

        #expect(model.current == "")
        #expect(model.revision == 2)
    }

    private func makeModel() -> (
        DefaultsValueModel<String>,
        AsyncStream<DefaultsEvent<String>>.Continuation
    ) {
        let store = UserDefaultsSettingsStore(
            defaults: UserDefaults(suiteName: "defaults-value-model-initial-\(UUID().uuidString)")!
        )
        let key = SettingCatalog().workspaceColors.selectionColorHex
        let (stream, continuation) = AsyncStream<DefaultsEvent<String>>.makeStream()
        let model = DefaultsValueModel(
            store: store,
            key: key,
            initialValue: "#000000",
            makeStream: { _ in stream }
        )
        return (model, continuation)
    }

    private func waitUntil(_ condition: () -> Bool) async {
        var spins = 0
        while !condition(), spins < 100_000 {
            await Task.yield()
            spins += 1
        }
    }
}
