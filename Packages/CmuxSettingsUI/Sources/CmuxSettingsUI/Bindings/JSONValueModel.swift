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
/// Lifecycle: the observation `Task` captures `self` weakly inside its
/// loop body and exits naturally when the model is deallocated.
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
    private let errorLog: SettingsErrorLog?

    /// Creates a model bound to ``key`` in ``store``.
    ///
    /// - Parameters:
    ///   - store: The JSON config store to read from and write to.
    ///   - key: The setting to observe.
    ///   - errorLog: Optional global log to push write failures into.
    ///     Pass `nil` for previews/tests; pass the runtime's log in
    ///     production so failures surface centrally.
    public init(
        store: JSONConfigStore,
        key: JSONKey<Value>,
        errorLog: SettingsErrorLog? = nil
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

    /// Writes ``value`` through to the JSON config file.
    ///
    /// On failure, ``lastWriteError`` is populated and the error is
    /// recorded in the injected ``SettingsErrorLog`` (if any).
    public func set(_ value: Value) {
        let keyID = key.id
        Task { [weak self, store, key] in
            do {
                try await store.set(value, for: key)
                await MainActor.run { self?.lastWriteError = nil }
            } catch {
                await MainActor.run {
                    self?.lastWriteError = error
                    self?.errorLog?.record(error, keyID: keyID)
                }
            }
        }
    }

    /// Removes the JSON entry. Parents that become empty are pruned.
    public func reset() {
        let keyID = key.id
        Task { [weak self, store, key] in
            do {
                try await store.reset(key)
                await MainActor.run { self?.lastWriteError = nil }
            } catch {
                await MainActor.run {
                    self?.lastWriteError = error
                    self?.errorLog?.record(error, keyID: keyID)
                }
            }
        }
    }
}
