import CmuxSettings
import Foundation
import Testing

@testable import CmuxSettingsUI

/// Lifecycle regression tests for ``DefaultsValueModel``.
///
/// The settings value models start a long-lived `Task` that iterates the
/// store's `values(for:)` change stream. That stream parks on
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
    /// Box whose flag the stream's `onTermination` flips on the main actor.
    @MainActor
    private final class TerminationFlag {
        var didTerminate = false
    }

    @Test func droppingModelTearsDownObservation() async {
        let store = UserDefaultsSettingsStore(
            defaults: UserDefaults(suiteName: "issue-5302-defaults-value-model")!
        )
        let key = SettingCatalog().betaFeatures.extensions

        let (stream, continuation) = AsyncStream<Bool>.makeStream()
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
        continuation.yield(true)
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
        let (stream, _) = AsyncStream<Bool>.makeStream()
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
        let (stream, _) = AsyncStream<Bool>.makeStream()
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
        let (stream, _) = AsyncStream<Bool>.makeStream()
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
        let (stream, _) = AsyncStream<Bool>.makeStream()
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
        let (stream, continuation) = AsyncStream<Bool>.makeStream()
        let model = DefaultsValueModel(
            store: store,
            key: key,
            makeStream: { stream }
        )
        model.startObserving()

        model.set(true)
        #expect(model.current == true)
        #expect(model.revision == 1)

        continuation.yield(true)
        continuation.yield(false)
        var spins = 0
        while model.current != false, spins < 100_000 {
            await Task.yield()
            spins += 1
        }

        #expect(model.current == false)
        #expect(model.revision == 2)
    }

    @Test func nonMatchingObservationClearsStaleLocalEcho() async {
        let store = UserDefaultsSettingsStore(
            defaults: UserDefaults(suiteName: "defaults-value-model-stale-echo")!
        )
        let key = SettingCatalog().betaFeatures.extensions
        let (stream, continuation) = AsyncStream<Bool>.makeStream()
        let model = DefaultsValueModel(
            store: store,
            key: key,
            makeStream: { stream }
        )
        model.startObserving()

        model.set(false)
        #expect(model.revision == 1)

        continuation.yield(true)
        var spins = 0
        while model.current != true, spins < 100_000 {
            await Task.yield()
            spins += 1
        }
        #expect(model.current == true)
        #expect(model.revision == 2)

        continuation.yield(false)
        spins = 0
        while model.current != false, spins < 100_000 {
            await Task.yield()
            spins += 1
        }
        #expect(model.current == false)
        #expect(model.revision == 3)
    }

    @Test func rapidLocalWriteEchoesDoNotRevertCurrentOrRevision() async {
        let store = UserDefaultsSettingsStore(
            defaults: UserDefaults(suiteName: "defaults-value-model-rapid-local-echoes")!
        )
        let key = SettingCatalog().workspaceColors.selectionColorHex
        let (stream, continuation) = AsyncStream<String>.makeStream()
        let model = DefaultsValueModel(
            store: store,
            key: key,
            initialValue: "#000000",
            makeStream: { stream }
        )
        model.startObserving()

        model.set("#111111")
        model.set("#222222")
        #expect(model.current == "#222222")
        #expect(model.revision == 2)

        continuation.yield("#111111")
        continuation.yield("#222222")
        continuation.yield("#333333")

        var spins = 0
        while model.current != "#333333", spins < 100_000 {
            await Task.yield()
            spins += 1
        }

        #expect(model.current == "#333333")
        #expect(model.revision == 3)
    }

    @Test func setAfterCommitRunsAfterStoreWrite() async {
        let suiteName = "defaults-value-model-after-commit"
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        let store = UserDefaultsSettingsStore(
            defaults: UserDefaults(suiteName: suiteName)!
        )
        let key = SettingCatalog().betaFeatures.extensions
        let (stream, _) = AsyncStream<Bool>.makeStream()
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
