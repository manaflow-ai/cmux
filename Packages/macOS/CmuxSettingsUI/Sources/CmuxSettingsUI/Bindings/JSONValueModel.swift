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
    /// ``current``, which updates once the write lands and the store
    /// yields it back. On failure ``lastWriteError`` is populated and
    /// recorded in the error log. Synchronous because SwiftUI `Binding`
    /// setters can't `await`.
    public func set(_ value: Value) {
        let keyID = key.id
        Task { [weak self, store, key] in
            do {
                try await store.set(value, for: key)
                await MainActor.run { self?.lastWriteError = nil }
            } catch {
                await MainActor.run {
                    self?.lastWriteError = error
                    self?.errorLog.record(error, keyID: keyID)
                }
            }
        }
    }

    /// Removes the JSON entry (parents that become empty are pruned).
    /// ``current`` updates when the stream observes the reset.
    public func reset() {
        let keyID = key.id
        Task { [weak self, store, key] in
            do {
                try await store.reset(key)
                await MainActor.run { self?.lastWriteError = nil }
            } catch {
                await MainActor.run {
                    self?.lastWriteError = error
                    self?.errorLog.record(error, keyID: keyID)
                }
            }
        }
    }
}
