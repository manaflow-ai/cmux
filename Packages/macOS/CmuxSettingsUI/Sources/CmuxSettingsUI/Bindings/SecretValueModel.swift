import CmuxSettings
import Foundation
import Observation

/// `@Observable` view-model that projects one ``SecretFileKey`` value into
/// SwiftUI-bindable state.
///
/// Same shape as ``DefaultsValueModel`` and ``JSONValueModel`` but bound to a
/// ``SecretFileStore``. The secret lives in its own `0600` file, never in the
/// shared `cmux.json`. Set / reset failures populate ``lastWriteError`` and
/// are pushed into the injected ``SettingsErrorLog`` so the UI surfaces them
/// centrally; the model never silently swallows a failure.
///
/// Lifecycle: the observation is owned by a ``SettingReadDriver`` held by the
/// model; the driver's `deinit` cancels the iterating task when the model
/// deallocates, finishing the change stream and tearing down its underlying
/// observation. A bare `weak self` is **not** enough — the parked task never
/// re-checks `self` for an idle key (see
/// https://github.com/manaflow-ai/cmux/issues/5302).
@MainActor
@Observable
public final class SecretValueModel {
    /// The most recently observed secret. SwiftUI views read this synchronously.
    public private(set) var current: String

    /// Error from the most recent set/reset attempt, or `nil`.
    public private(set) var lastWriteError: Error?

    private let store: SecretFileStore
    private let key: SecretFileKey
    private let errorLog: SettingsErrorLog
    @ObservationIgnored private let makeStream: () -> AsyncStream<String>

    /// Owns the change-stream subscription and cancels it when this model
    /// deallocates.
    @ObservationIgnored private let observation = SettingReadDriver<String>()

    /// Creates a model bound to ``key`` in ``store``.
    ///
    /// - Parameters:
    ///   - store: The secret-file store to read from and write to.
    ///   - key: The secret to observe.
    ///   - errorLog: Global log that write failures are pushed into.
    public convenience init(
        store: SecretFileStore,
        key: SecretFileKey,
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
    ///   - store: The secret-file store used for writes (`set`/`reset`).
    ///   - key: The secret to observe.
    ///   - errorLog: Global log that write failures are pushed into.
    ///   - makeStream: Builds the change stream this model iterates.
    init(
        store: SecretFileStore,
        key: SecretFileKey,
        errorLog: SettingsErrorLog,
        makeStream: @escaping () -> AsyncStream<String>
    ) {
        self.store = store
        self.key = key
        self.errorLog = errorLog
        self.makeStream = makeStream
        self.current = key.defaultValue
    }

    /// Starts the secret-file change stream for the retained model.
    ///
    /// Idempotent: the first call starts observation and later calls are
    /// ignored by ``SettingReadDriver``. Views should call this from a mounted
    /// lifecycle hook such as `.task`, not from their initializer.
    public func startObserving() {
        observation.activate(makeStream) { [weak self] value in
            self?.current = value
        }
    }

    /// Persists the secret. The observation stream is the single writer of
    /// ``current``. On failure ``lastWriteError`` is populated and recorded.
    public func set(_ value: String) {
        let keyID = key.id
        // The Task inherits this method's `@MainActor` isolation, so the
        // completion assignments already run on the main actor.
        Task { [weak self, store, key] in
            do {
                try await store.set(value, for: key)
                self?.lastWriteError = nil
            } catch {
                self?.lastWriteError = error
                self?.errorLog.record(error, keyID: keyID)
            }
        }
    }

    /// Clears the secret (deletes its file). ``current`` updates when the
    /// stream observes the reset.
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
