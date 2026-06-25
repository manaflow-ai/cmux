import CmuxSettings
import Foundation
import Testing

@testable import CmuxSettingsUI

/// Lifecycle regression tests for ``DefaultsValueModel``.
///
/// The settings value models start a long-lived `Task` that iterates the
/// store's `valueEvents(for:)` change stream. That stream parks on
/// `NotificationCenter.default.notifications(named:)`, which rarely fires for
/// an idle key, so the iterating task is suspended indefinitely. If the model
/// only relies on `weak self` for teardown, dropping the model never reaches
/// the `guard let self` check (the task is parked at the `await`), so the
/// task — and the `AsyncStream` + notification sequence it keeps alive — leak.
///
/// `State(initialValue: DefaultsValueModel(...))` re-runs on every parent
/// render, constructing throwaway models, so each leaked trio accumulates
/// monotonically (see https://github.com/manaflow-ai/cmux/issues/5302).
///
/// This suite proves the model cancels its observation when it deallocates by
/// observing the injected stream's `onTermination`: cancellation of the
/// model's iterating task finishes the stream and fires `onTermination`.
@MainActor
@Suite struct DefaultsValueModelLifecycleTests {
    private typealias DefaultsEvent<Value: SettingCodable> = UserDefaultsSettingsValueEvent<Value>

    /// Box whose flag the stream's `onTermination` flips on the main actor.
    @MainActor
    private final class TerminationFlag {
        var didTerminate = false
    }

    private func event<Value: SettingCodable>(
        _ value: Value,
        source: UserDefaultsSettingsMutationSource? = nil
    ) -> DefaultsEvent<Value> {
        DefaultsEvent(value: value, mutationSource: source)
    }

    @Test func droppingModelTearsDownObservation() async {
        let store = UserDefaultsSettingsStore(
            defaults: UserDefaults(suiteName: "issue-5302-defaults-value-model")!
        )
        let key = SettingCatalog().betaFeatures.extensions

        let (stream, continuation) = AsyncStream<DefaultsEvent<Bool>>.makeStream()
        let flag = TerminationFlag()
        continuation.onTermination = { _ in
            Task { @MainActor in flag.didTerminate = true }
        }

        var model: DefaultsValueModel<Bool>? = DefaultsValueModel(
            store: store,
            key: key,
            makeStream: { stream }
        )
        model?.startObserving()

        // Drive one value through so the model's task is parked awaiting the
        // next element — the exact suspended state where `weak self` teardown
        // never runs.
        continuation.yield(event(true))
        var settleSpins = 0
        while model?.current != true, settleSpins < 100_000 {
            await Task.yield()
            settleSpins += 1
        }
        #expect(model?.current == true)

        // Drop the model. A model that owns and cancels its observation will
        // cancel the parked task, finishing the stream and firing
        // `onTermination`. A model that leaks it never will.
        model = nil

        var spins = 0
        while !flag.didTerminate, spins < 100_000 {
            await Task.yield()
            spins += 1
        }
        #expect(flag.didTerminate)
    }

    @Test func initializationDoesNotStartObservationStream() {
        let store = UserDefaultsSettingsStore(
            defaults: UserDefaults(suiteName: "defaults-value-model-lazy-observation")!
        )
        let key = SettingCatalog().betaFeatures.extensions
        let (stream, _) = AsyncStream<DefaultsEvent<Bool>>.makeStream()
        var streamCreations = 0

        _ = DefaultsValueModel(
            store: store,
            key: key,
            makeStream: {
                streamCreations += 1
                return stream
            }
        )

        #expect(streamCreations == 0)
    }

    @Test func setUpdatesCurrentBeforeObservationRoundTrip() {
        let store = UserDefaultsSettingsStore(
            defaults: UserDefaults(suiteName: "defaults-value-model-optimistic-set")!
        )
        let key = SettingCatalog().betaFeatures.extensions
        let (stream, _) = AsyncStream<DefaultsEvent<Bool>>.makeStream()
        let model = DefaultsValueModel(
            store: store,
            key: key,
            makeStream: { stream }
        )

        #expect(model.current == false)
        model.set(true)
        #expect(model.current == true)

        model.reset()
        #expect(model.current == false)
    }

    @Test func acceptCommittedValueUpdatesCurrentWithoutStoreWrite() {
        let suiteName = "defaults-value-model-committed-value"
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        let store = UserDefaultsSettingsStore(
            defaults: UserDefaults(suiteName: suiteName)!
        )
        let key = SettingCatalog().betaFeatures.extensions
        let (stream, _) = AsyncStream<DefaultsEvent<Bool>>.makeStream()
        let model = DefaultsValueModel(
            store: store,
            key: key,
            makeStream: { stream }
        )

        #expect(model.current == false)
        model.acceptCommittedValue(true)
        #expect(model.current == true)
        #expect(UserDefaults(suiteName: suiteName)?.object(forKey: key.userDefaultsKey) == nil)
    }

    @Test func revisionAdvancesForSameValueWrites() {
        let store = UserDefaultsSettingsStore(
            defaults: UserDefaults(suiteName: "defaults-value-model-revision")!
        )
        let key = SettingCatalog().betaFeatures.extensions
        let (stream, _) = AsyncStream<DefaultsEvent<Bool>>.makeStream()
        let model = DefaultsValueModel(
            store: store,
            key: key,
            makeStream: { stream }
        )

        #expect(model.current == false)
        #expect(model.revision == 0)

        model.set(false)
        #expect(model.current == false)
        #expect(model.revision == 1)

        model.acceptCommittedValue(false)
        #expect(model.current == false)
        #expect(model.revision == 2)

        model.reset()
        #expect(model.current == false)
        #expect(model.revision == 3)
    }

    @Test func localWriteEchoDoesNotAdvanceRevision() async {
        let store = UserDefaultsSettingsStore(
            defaults: UserDefaults(suiteName: "defaults-value-model-local-echo")!
        )
        let key = SettingCatalog().betaFeatures.extensions
        let (stream, continuation) = AsyncStream<DefaultsEvent<Bool>>.makeStream()
        let model = DefaultsValueModel(
            store: store,
            key: key,
            makeStream: { stream }
        )
        model.startObserving()

        let source = model.set(true)
        #expect(model.current == true)
        #expect(model.revision == 1)

        continuation.yield(event(true, source: source))
        continuation.yield(event(false))
        var spins = 0
        while model.current != false, spins < 100_000 {
            await Task.yield()
            spins += 1
        }

        #expect(model.current == false)
        #expect(model.revision == 2)
    }

    @Test func initialStaleObservationDoesNotConsumePendingLocalEcho() async {
        let store = UserDefaultsSettingsStore(
            defaults: UserDefaults(suiteName: "defaults-value-model-stale-initial")!
        )
        let key = SettingCatalog().workspaceColors.selectionColorHex
        let (stream, continuation) = AsyncStream<DefaultsEvent<String>>.makeStream()
        let model = DefaultsValueModel(
            store: store,
            key: key,
            initialValue: "#000000",
            makeStream: { stream }
        )

        let source = model.set("#111111")
        model.startObserving()

        continuation.yield(event("#000000"))
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

    @Test func externalObservationSuppressesLaterStaleLocalEcho() async {
        let store = UserDefaultsSettingsStore(
            defaults: UserDefaults(suiteName: "defaults-value-model-stale-echo")!
        )
        let key = SettingCatalog().betaFeatures.extensions
        let (stream, continuation) = AsyncStream<DefaultsEvent<Bool>>.makeStream()
        let model = DefaultsValueModel(
            store: store,
            key: key,
            makeStream: { stream }
        )
        model.startObserving()

        continuation.yield(event(false))
        var spins = 0
        while model.revision != 1, spins < 100_000 {
            await Task.yield()
            spins += 1
        }
        #expect(model.current == false)
        #expect(model.revision == 1)

        let source = model.set(false)
        #expect(model.revision == 2)

        continuation.yield(event(true))
        spins = 0
        while model.current != true, spins < 100_000 {
            await Task.yield()
            spins += 1
        }
        #expect(model.current == true)
        #expect(model.revision == 3)

        continuation.yield(event(false, source: source))
        for _ in 0..<10 {
            await Task.yield()
        }
        #expect(model.current == true)
        #expect(model.revision == 3)
    }

    @Test func rapidLocalWriteEchoesDoNotRevertCurrentOrRevision() async {
        let store = UserDefaultsSettingsStore(
            defaults: UserDefaults(suiteName: "defaults-value-model-rapid-local-echoes")!
        )
        let key = SettingCatalog().workspaceColors.selectionColorHex
        let (stream, continuation) = AsyncStream<DefaultsEvent<String>>.makeStream()
        let model = DefaultsValueModel(
            store: store,
            key: key,
            initialValue: "#000000",
            makeStream: { stream }
        )
        model.startObserving()

        let firstSource = model.set("#111111")
        let secondSource = model.set("#222222")
        #expect(model.current == "#222222")
        #expect(model.revision == 2)

        continuation.yield(event("#111111", source: firstSource))
        continuation.yield(event("#222222", source: secondSource))
        continuation.yield(event("#333333"))

        var spins = 0
        while model.current != "#333333", spins < 100_000 {
            await Task.yield()
            spins += 1
        }

        #expect(model.current == "#333333")
        #expect(model.revision == 3)
    }

    @Test func repeatedLocalWriteEchoesConsumeOnlyObservedPendingValue() async {
        let store = UserDefaultsSettingsStore(
            defaults: UserDefaults(suiteName: "defaults-value-model-repeated-local-echoes")!
        )
        let key = SettingCatalog().workspaceColors.selectionColorHex
        let (stream, continuation) = AsyncStream<DefaultsEvent<String>>.makeStream()
        let model = DefaultsValueModel(
            store: store,
            key: key,
            initialValue: "#000000",
            makeStream: { stream }
        )
        model.startObserving()

        let firstSource = model.set("#111111")
        let secondSource = model.set("#222222")
        let thirdSource = model.set("#111111")
        let fourthSource = model.set("#333333")
        #expect(model.current == "#333333")
        #expect(model.revision == 4)

        continuation.yield(event("#111111", source: firstSource))
        continuation.yield(event("#222222", source: secondSource))
        continuation.yield(event("#111111", source: thirdSource))
        continuation.yield(event("#333333", source: fourthSource))
        continuation.yield(event("#444444"))

        var spins = 0
        while model.current != "#444444", spins < 100_000 {
            await Task.yield()
            spins += 1
        }

        #expect(model.current == "#444444")
        #expect(model.revision == 5)
    }

    @Test func coalescedLocalWriteEchoSuppressesOlderLocalEchoes() async {
        let store = UserDefaultsSettingsStore(
            defaults: UserDefaults(suiteName: "defaults-value-model-coalesced-local-echoes")!
        )
        let key = SettingCatalog().workspaceColors.selectionColorHex
        let (stream, continuation) = AsyncStream<DefaultsEvent<String>>.makeStream()
        let model = DefaultsValueModel(
            store: store,
            key: key,
            initialValue: "#000000",
            makeStream: { stream }
        )
        model.startObserving()

        let firstSource = model.set("#111111")
        _ = model.set("#222222")
        let thirdSource = model.set("#333333")
        #expect(model.current == "#333333")
        #expect(model.revision == 3)

        continuation.yield(event("#333333", source: thirdSource))
        continuation.yield(event("#111111", source: firstSource))

        for _ in 0..<10 {
            await Task.yield()
        }

        #expect(model.current == "#333333")
        #expect(model.revision == 3)
    }

    @Test func coalescedDuplicateLocalWriteEchoSuppressesOlderLocalEchoes() async {
        let store = UserDefaultsSettingsStore(
            defaults: UserDefaults(suiteName: "defaults-value-model-coalesced-duplicate-local-echoes")!
        )
        let key = SettingCatalog().workspaceColors.selectionColorHex
        let (stream, continuation) = AsyncStream<DefaultsEvent<String>>.makeStream()
        let model = DefaultsValueModel(
            store: store,
            key: key,
            initialValue: "#000000",
            makeStream: { stream }
        )
        model.startObserving()

        _ = model.set("#111111")
        let secondSource = model.set("#222222")
        let thirdSource = model.set("#111111")
        #expect(model.current == "#111111")
        #expect(model.revision == 3)

        continuation.yield(event("#111111", source: thirdSource))
        continuation.yield(event("#222222", source: secondSource))

        for _ in 0..<10 {
            await Task.yield()
        }

        #expect(model.current == "#111111")
        #expect(model.revision == 3)
    }

    @Test func overflowedLocalWriteEchoDoesNotClearNewerPendingValues() async {
        let store = UserDefaultsSettingsStore(
            defaults: UserDefaults(suiteName: "defaults-value-model-overflowed-local-echoes")!
        )
        let key = SettingCatalog().workspaceColors.selectionColorHex
        let (stream, continuation) = AsyncStream<DefaultsEvent<String>>.makeStream()
        let model = DefaultsValueModel(
            store: store,
            key: key,
            initialValue: "#000000",
            makeStream: { stream }
        )
        model.startObserving()

        let writes = (1...20).map { "#LOCAL-\($0)" }
        var sources: [UserDefaultsSettingsMutationSource] = []
        for value in writes {
            sources.append(model.set(value))
        }

        #expect(model.current == "#LOCAL-20")
        #expect(model.revision == 20)

        continuation.yield(event("#LOCAL-1", source: sources[0]))
        for _ in 0..<10 {
            await Task.yield()
        }

        #expect(model.current == "#LOCAL-20")
        #expect(model.revision == 20)

        continuation.yield(event("#EXTERNAL"))
        var spins = 0
        while model.current != "#EXTERNAL", spins < 100_000 {
            await Task.yield()
            spins += 1
        }

        #expect(model.current == "#EXTERNAL")
        #expect(model.revision == 21)
    }

    @Test func setAfterCommitRunsAfterStoreWrite() async {
        let suiteName = "defaults-value-model-after-commit"
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        let store = UserDefaultsSettingsStore(
            defaults: UserDefaults(suiteName: suiteName)!
        )
        let key = SettingCatalog().betaFeatures.extensions
        let (stream, _) = AsyncStream<DefaultsEvent<Bool>>.makeStream()
        let model = DefaultsValueModel(
            store: store,
            key: key,
            makeStream: { stream }
        )

        let valueObservedAfterCommit = await withCheckedContinuation { continuation in
            model.set(true) {
                continuation.resume(returning: store.initialValue(for: key))
            }
        }

        #expect(valueObservedAfterCommit == true)
    }
}
