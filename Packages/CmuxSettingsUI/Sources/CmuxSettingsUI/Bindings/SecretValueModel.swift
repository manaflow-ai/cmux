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
/// Lifecycle: the observation `Task` captures `self` weakly and exits when the
/// model is deallocated.
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

    /// Creates a model bound to ``key`` in ``store``.
    ///
    /// - Parameters:
    ///   - store: The secret-file store to read from and write to.
    ///   - key: The secret to observe.
    ///   - errorLog: Global log that write failures are pushed into.
    public init(
        store: SecretFileStore,
        key: SecretFileKey,
        errorLog: SettingsErrorLog
    ) {
        self.store = store
        self.key = key
        self.errorLog = errorLog
        self.current = key.defaultValue
        Task { [weak self, store, key] in
            for await value in store.values(for: key) {
                guard let self else { return }
                if Task.isCancelled { break }
                self.current = value
            }
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
