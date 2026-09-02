import CmuxSettings
import Foundation
import Observation

/// `@Observable` view-model that projects one ``JSONKey`` value into
/// SwiftUI-bindable state.
///
/// Same shape as ``DefaultsValueModel`` but bound to a ``JSONConfigStore``.
/// Set / reset failures populate the model's ``lastWriteError`` *and* are
/// pushed into the optional injected ``SettingsErrorLog`` so the UI can
/// surface them centrally; the model never silently swallows a failure.
///
/// Lifecycle: the observation is owned by a ``SettingReadDriver`` held by the
/// model; the driver's `deinit` cancels the iterating task when the model
/// deallocates, finishing the change stream and tearing down its underlying
/// observation. A bare `weak self` is **not** enough — the parked task never
/// re-checks `self` for an idle key (see
/// https://github.com/manaflow-ai/cmux/issues/5302).
@MainActor
@Observable
public final class JSONValueModel<Value: SettingCodable> {
    /// The most recently observed value. Updated by the JSON store's file
    /// watcher.
    public private(set) var current: Value

    /// Error from the most recent set/reset attempt, or `nil`.
    public private(set) var lastWriteError: Error?

    private let store: JSONConfigStore
    private let key: JSONKey<Value>
    private let errorLog: SettingsErrorLog
    @ObservationIgnored private let makeStream: () -> AsyncStream<Value>

    /// Owns the change-stream subscription and cancels it when this model
    /// deallocates.
    @ObservationIgnored private let observation = SettingReadDriver<Value>()

    /// Owns the most recent persistence task so synchronous SwiftUI bindings
    /// do not leave an untracked operation behind. A new write supersedes the
    /// previous task; the store actor still serializes operations that have
    /// already reached it.
    @ObservationIgnored private var pendingWriteTask: Task<Void, Never>?

    /// Creates a model bound to ``key`` in ``store``.
    ///
    /// - Parameters:
    ///   - store: The JSON config store to read from and write to.
    ///   - key: The setting to observe.
    ///   - errorLog: Global log that write failures are pushed into so
    ///     they surface centrally. The runtime always provides one; see
    ///     ``SettingsRuntime/errorLog``.
    public convenience init(
        store: JSONConfigStore,
        key: JSONKey<Value>,
        errorLog: SettingsErrorLog
    ) {
        self.init(
            store: store,
            key: key,
            errorLog: errorLog,
            makeStream: { store.values(for: key) }
        )
    }

    /// Designated initializer with an injectable change-stream factory.
    ///
    /// The `makeStream` seam lets tests drive the observation with a stream
    /// whose teardown they can observe. Production code uses the public
    /// `init(store:key:errorLog:)`, which wires `makeStream` to the store.
    ///
    /// - Parameters:
    ///   - store: The JSON config store used for writes (`set`/`reset`).
    ///   - key: The setting to observe.
    ///   - errorLog: Global log that write failures are pushed into.
    ///   - makeStream: Builds the change stream this model iterates.
    init(
        store: JSONConfigStore,
        key: JSONKey<Value>,
        errorLog: SettingsErrorLog,
        makeStream: @escaping () -> AsyncStream<Value>
    ) {
        self.store = store
        self.key = key
        self.errorLog = errorLog
        self.makeStream = makeStream
        self.current = key.defaultValue
    }

    deinit {
        pendingWriteTask?.cancel()
    }

    /// Starts the JSON change stream for the retained model.
    ///
    /// Idempotent: the first call starts observation and later calls are
    /// ignored by ``SettingReadDriver``. Views should call this from a mounted
    /// lifecycle hook such as `.task`, not from their initializer.
    public func startObserving() {
        observation.activate(makeStream) { [weak self] value in
            self?.current = value
        }
    }

    /// Persists the value. The observation stream is the single writer of
    /// ``current``, which updates once the write lands and the store yields it
    /// back. Synchronous bindings can ignore the returned task, while async
    /// callers may await its ``Task/value`` to observe completion.
    @discardableResult
    public func set(_ value: Value) -> Task<Void, Never> {
        enqueueWrite { store, key in
            try await store.set(value, for: key)
        }
    }

    /// Atomically transforms the latest persisted value and writes the result.
    ///
    /// Unlike ``set(_:)``, this operation does not base the write on the
    /// view-model snapshot. It is intended for editors that merge one field
    /// into a shared dictionary and must preserve concurrent changes.
    ///
    /// - Parameter transform: A pure transformation applied by the store actor.
    @discardableResult
    public func update(_ transform: @escaping @Sendable (Value) -> Value) -> Task<Void, Never> {
        enqueueWrite { store, key in
            _ = try await store.update(key, transform: transform)
        }
    }

    /// Removes the JSON entry (parents that become empty are pruned).
    /// ``current`` updates when the stream observes the reset.
    @discardableResult
    public func reset() -> Task<Void, Never> {
        enqueueWrite { store, key in
            try await store.reset(key)
        }
    }

    /// Enqueues one actor-isolated persistence operation and retains its task
    /// for lifecycle cancellation. The closure runs on the main actor before
    /// and after the store hop, so updates to ``lastWriteError`` stay isolated.
    private func enqueueWrite(
        _ operation: @escaping @Sendable (JSONConfigStore, JSONKey<Value>) async throws -> Void
    ) -> Task<Void, Never> {
        pendingWriteTask?.cancel()
        let keyID = key.id
        let task = Task { @MainActor [weak self, store, key] in
            do {
                try await operation(store, key)
                guard !Task.isCancelled else { return }
                self?.lastWriteError = nil
            } catch is CancellationError {
                // Cancellation is an expected lifecycle/supersession path;
                // do not surface it as a settings write failure.
            } catch {
                guard !Task.isCancelled else { return }
                self?.lastWriteError = error
                self?.errorLog.record(error, keyID: keyID)
            }
        }
        pendingWriteTask = task
        return task
    }
}
