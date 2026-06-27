import CmuxSettings
import Foundation
import Observation

/// `@Observable` view-model that projects one ``DefaultsKey`` value into
/// SwiftUI-bindable state.
///
/// SwiftUI views need synchronous reads against a `Binding<Value>` in
/// their body. The ``UserDefaultsSettingsStore`` API is `async`, so we
/// can't bind directly. ``DefaultsValueModel`` is the bridge:
///
/// 1. On construction it seeds ``current`` from the synchronous
///    `UserDefaults` value, but does not subscribe yet. ``startObserving()``
///    subscribes to
///    ``UserDefaultsSettingsStore/valueEvents(for:)`` once the owning SwiftUI view
///    is mounted. That stream is `.bufferingNewest(1)`, so a burst of writes
///    (e.g. a `ColorPicker` drag) coalesces to the latest value instead of
///    replaying every intermediate back through ``current``.
/// 2. SwiftUI views read ``current`` synchronously and write via ``set(_:)``.
/// 3. ``set(_:)`` updates ``current`` optimistically (immediate UI) and
///    persists the write in a fire-and-forget `Task`. ``set(_:afterCommit:)``
///    uses the same store path, then runs a main-actor side effect after the
///    async write has committed.
///
/// Lifecycle: the observation is owned by a ``SettingReadDriver`` held by the
/// model. When the model deallocates, the driver's `deinit` cancels the
/// iterating task, which finishes the change stream and tears down its
/// underlying `NotificationCenter.notifications(named:)` sequence. A bare
/// `weak self` inside the loop is **not** enough — the task is parked at the
/// `await` and never re-checks `self` for an idle key, leaking the
/// subscription (see https://github.com/manaflow-ai/cmux/issues/5302).
@MainActor
@Observable
public final class DefaultsValueModel<Value: SettingCodable> {
    /// The most recently observed value. SwiftUI views read this synchronously.
    public private(set) var current: Value
    private(set) var revision = 0

    private let store: UserDefaultsSettingsStore
    private let key: DefaultsKey<Value>
    private let initialStoreValue: Value
    @ObservationIgnored private let makeStream:
        @MainActor @Sendable (Set<UserDefaultsSettingsMutationSource>) async -> AsyncStream<UserDefaultsSettingsValueEvent<Value>>
    @ObservationIgnored private var pendingStoreEchoes: [(source: UserDefaultsSettingsMutationSource, value: Value)] = []
    @ObservationIgnored private let maximumPendingStoreEchoes = 16
    @ObservationIgnored private let mutationOwnerID = UUID()
    @ObservationIgnored private var nextMutationSequence: UInt64 = 0
    @ObservationIgnored private var minimumRetainedMutationSequence: UInt64 = 1
    @ObservationIgnored private var hasObservedInitialStoreEvent = false

    /// Owns the change-stream subscription and cancels it when this model
    /// deallocates.
    @ObservationIgnored private let observation = SettingReadDriver<UserDefaultsSettingsValueEvent<Value>>()

    /// Creates a model bound to ``key`` in ``store``.
    ///
    /// - Parameters:
    ///   - store: The UserDefaults store to read from and write to.
    ///   - key: The setting to observe.
    public convenience init(store: UserDefaultsSettingsStore, key: DefaultsKey<Value>) {
        self.init(
            store: store,
            key: key,
            initialValue: store.initialValue(for: key),
            makeStream: { sources in await store.valueEvents(for: key, includingSources: sources) }
        )
    }

    /// Designated initializer with an injectable change-stream factory.
    ///
    /// The `makeStream` seam lets tests drive the observation with a stream
    /// whose teardown they can observe, proving the model cancels its
    /// observation on deallocation. Production code uses the public
    /// `init(store:key:)`, which wires `makeStream` to the store's actor-isolated
    /// source-tagged event stream.
    ///
    /// - Parameters:
    ///   - store: The UserDefaults store used for writes (`set`/`reset`).
    ///   - key: The setting to observe.
    ///   - makeStream: Builds the change stream this model iterates.
    init(
        store: UserDefaultsSettingsStore,
        key: DefaultsKey<Value>,
        initialValue: Value? = nil,
        makeStream: @escaping @MainActor @Sendable (
            Set<UserDefaultsSettingsMutationSource>
        ) async -> AsyncStream<UserDefaultsSettingsValueEvent<Value>>
    ) {
        self.store = store
        self.key = key
        self.makeStream = makeStream
        // Keep init side-effect-light. SwiftUI may evaluate
        // `State(initialValue:)` for throwaway view values during layout, so
        // observing starts only after the retained view appears.
        let resolvedInitialValue = initialValue ?? key.defaultValue
        self.initialStoreValue = resolvedInitialValue
        self.current = resolvedInitialValue
    }

    /// Starts the settings change stream for the retained model.
    ///
    /// Idempotent: the first call starts observation and later calls are
    /// ignored by ``SettingReadDriver``. Views should call this from a mounted
    /// lifecycle hook such as `.task`, not from their initializer.
    public func startObserving() {
        let makeStream = self.makeStream
        observation.activateAsync({ [weak self] in
            guard let self else {
                return AsyncStream { continuation in continuation.finish() }
            }
            let pendingSources = Set(self.pendingStoreEchoes.map(\.source))
            return await makeStream(pendingSources)
        }) { [weak self] value in
            self?.acceptObservedValue(value)
        }
    }

    /// Persists the value. The observation stream is the single writer of
    /// ``current`` for external changes, but direct UI writes update it
    /// optimistically before the async storage write. Synchronous because
    /// SwiftUI `Binding` setters can't `await`; the write itself runs in a
    /// fire-and-forget `Task`.
    @discardableResult
    public func set(_ value: Value) -> UserDefaultsSettingsMutationSource {
        let source = recordPendingStoreEcho(value)
        updateCurrent(value)
        Task { @MainActor [self, store, key, source, value] in
            guard await store.set(value, for: key, source: source) != nil else {
                let committedValue = await store.value(for: key)
                reconcileRejectedStoreWrite(source: source, committedValue: committedValue)
                return
            }
        }
        return source
    }

    /// Persists the value, then runs `afterCommit` after storage accepts it.
    ///
    /// Use this when a setting has host-side live-update work that must observe
    /// the committed defaults value. The write still goes through the injected
    /// ``UserDefaultsSettingsStore`` instead of assuming `UserDefaults.standard`.
    ///
    /// - Parameters:
    ///   - value: The new value to persist.
    ///   - afterCommit: Main-actor work to run after ``UserDefaultsSettingsStore``
    ///     has completed the write.
    @discardableResult
    public func set(
        _ value: Value,
        afterCommit: @escaping @MainActor @Sendable () -> Void
    ) -> UserDefaultsSettingsMutationSource {
        let source = recordPendingStoreEcho(value)
        updateCurrent(value)
        Task { @MainActor [self, store, key, source, value, afterCommit] in
            guard await store.set(value, for: key, source: source) != nil else {
                let committedValue = await store.value(for: key)
                reconcileRejectedStoreWrite(source: source, committedValue: committedValue)
                return
            }
            afterCommit()
        }
        return source
    }

    /// Updates ``current`` after another owner has already persisted `value`.
    ///
    /// Use this for settings whose committed write spans multiple backing keys
    /// and must stay in one host-owned mutation path. Unlike ``set(_:)``, this
    /// method does not write to ``store``.
    public func acceptCommittedValue(_ value: Value) {
        clearPendingStoreEchoes()
        updateCurrent(value)
    }

    /// Removes the override and updates ``current`` optimistically while the
    /// async store write is in flight.
    @discardableResult
    public func reset() -> UserDefaultsSettingsMutationSource {
        let defaultValue = key.defaultValue
        let source = recordPendingStoreEcho(defaultValue)
        updateCurrent(defaultValue)
        Task { @MainActor [self, store, key, source] in
            guard await store.reset(key, source: source) != nil else {
                let committedValue = await store.value(for: key)
                reconcileRejectedStoreWrite(source: source, committedValue: committedValue)
                return
            }
        }
        return source
    }

    private func acceptObservedValue(_ event: UserDefaultsSettingsValueEvent<Value>) {
        let isInitialStoreEvent = !hasObservedInitialStoreEvent
        hasObservedInitialStoreEvent = true

        let echoConsumption = consumePendingStoreEcho(source: event.mutationSource, value: event.value)
        if echoConsumption.consumed {
            if echoConsumption.shouldUpdateCurrent {
                updateCurrent(event.value)
            }
            return
        }
        if isInitialStoreEvent,
           event.isInitialSnapshot,
           event.mutationSource == nil,
           event.supersededMutationSource == nil,
           !pendingStoreEchoes.isEmpty,
           event.value == initialStoreValue {
            return
        }
        if let supersededSource = event.supersededMutationSource,
           supersededSource.ownerID == mutationOwnerID,
           consumeSupersededPendingStoreEcho(source: supersededSource) {
            return
        }
        updateCurrent(event.value)
    }

    private func updateCurrent(_ value: Value) {
        current = value
        revision &+= 1
    }

    private func recordPendingStoreEcho(_ value: Value) -> UserDefaultsSettingsMutationSource {
        nextMutationSequence &+= 1
        let source = UserDefaultsSettingsMutationSource(
            ownerID: mutationOwnerID,
            sequence: nextMutationSequence
        )
        pendingStoreEchoes.append((source, value))
        let overflow = pendingStoreEchoes.count - maximumPendingStoreEchoes
        if overflow > 0 {
            if let lastRemoved = pendingStoreEchoes.prefix(overflow).last {
                markLocalEchoesConsumed(through: lastRemoved.source.sequence)
            }
            pendingStoreEchoes.removeFirst(overflow)
        }
        return source
    }

    private func consumePendingStoreEcho(
        source: UserDefaultsSettingsMutationSource?,
        value: Value
    ) -> (consumed: Bool, shouldUpdateCurrent: Bool) {
        guard let source, source.ownerID == mutationOwnerID else {
            return (false, false)
        }

        guard let matchingIndex = pendingStoreEchoes.firstIndex(where: { $0.source == source && $0.value == value }) else {
            return (source.sequence < minimumRetainedMutationSequence, false)
        }

        let hasNewerPendingEcho = matchingIndex < pendingStoreEchoes.index(before: pendingStoreEchoes.endIndex)
        markLocalEchoesConsumed(through: source.sequence)
        pendingStoreEchoes.removeFirst(matchingIndex + 1)
        return (true, !hasNewerPendingEcho && current != value)
    }

    private func consumeSupersededPendingStoreEcho(source: UserDefaultsSettingsMutationSource) -> Bool {
        if let matchingIndex = pendingStoreEchoes.firstIndex(where: { $0.source == source }) {
            markLocalEchoesConsumed(through: source.sequence)
            pendingStoreEchoes.removeFirst(matchingIndex + 1)
        } else if source.sequence < minimumRetainedMutationSequence {
            return !pendingStoreEchoes.isEmpty
        }

        return !pendingStoreEchoes.isEmpty
    }

    private func reconcileRejectedStoreWrite(
        source: UserDefaultsSettingsMutationSource,
        committedValue: Value
    ) {
        guard let matchingIndex = pendingStoreEchoes.firstIndex(where: { $0.source == source }) else {
            return
        }
        guard matchingIndex == pendingStoreEchoes.index(before: pendingStoreEchoes.endIndex) else {
            return
        }

        markLocalEchoesConsumed(through: source.sequence)
        pendingStoreEchoes.removeFirst(matchingIndex + 1)
        updateCurrent(committedValue)
    }

    private func clearPendingStoreEchoes() {
        if let newestPendingSource = pendingStoreEchoes.last?.source {
            markLocalEchoesConsumed(through: newestPendingSource.sequence)
        }
        pendingStoreEchoes.removeAll()
    }

    private func markLocalEchoesConsumed(through sequence: UInt64) {
        if sequence >= minimumRetainedMutationSequence {
            minimumRetainedMutationSequence = sequence == UInt64.max ? UInt64.max : sequence + 1
        }
    }
}
