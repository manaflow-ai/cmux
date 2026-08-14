import CmuxSettings
import CmuxSettingsUI
import Foundation
import OSLog

nonisolated private let pluginShortcutStoreLogger = Logger(
    subsystem: "com.cmuxterm.app",
    category: "PluginShortcutStore"
)

/// Actor-backed persistence plus a lock-protected projection for shortcut
/// matching, which must remain synchronous on AppKit's key-event path.
final class CmuxPluginShortcutStore: @unchecked Sendable {
    private static let key = JSONKey<[String: CmuxPluginShortcutBinding]>(
        id: "shortcuts.pluginBindings",
        defaultValue: [:]
    )

    private let jsonStore: JSONConfigStore
    private let onChange: @MainActor @Sendable () -> Void
    private let lock = NSLock()
    private var rawBindings: [String: CmuxPluginShortcutBinding]
    private var observationTask: Task<Void, Never>?
    private var mutationTail: Task<Void, Never>?

    /// The lock is a narrow synchronous projection carve-out: AppKit's key
    /// monitor cannot suspend, while the actor remains authoritative for disk
    /// reads/writes. No caller uses this lock for a long-lived domain state.
    init(
        jsonStore: JSONConfigStore,
        onChange: @escaping @MainActor @Sendable () -> Void
    ) {
        self.jsonStore = jsonStore
        self.onChange = onChange
        self.rawBindings = jsonStore.snapshotValue(for: Self.key)
        observationTask = nil
        mutationTail = nil
        observationTask = Task { [weak self, jsonStore] in
            for await values in jsonStore.values(for: Self.key) {
                guard let self else { return }
                self.replace(values)
            }
        }
    }

    deinit {
        observationTask?.cancel()
        mutationTail?.cancel()
    }

    /// Returns a parsed binding without touching disk.
    func shortcut(for actionID: String) -> StoredShortcut? {
        lock.lock()
        let raw = rawBindings[actionID]
        lock.unlock()
        return raw?.shortcut
    }

    /// Returns all valid persisted bindings.
    func shortcuts() -> [String: StoredShortcut] {
        lock.lock()
        let values = rawBindings
        lock.unlock()
        return values.compactMapValues(\.shortcut)
    }

    /// Refreshes the synchronous projection from the config file after an
    /// external settings watcher reports a change.
    func refreshFromDisk() {
        replace(jsonStore.snapshotValue(for: Self.key))
    }

    /// Schedules an atomic map update and publishes the normal shortcut
    /// notifications after the JSON store accepts it.
    func set(_ shortcut: StoredShortcut, actionID: String) {
        let binding = CmuxPluginShortcutBinding(shortcut)
        enqueueMutation { [weak self, jsonStore] in
            do {
                let values = try await jsonStore.update(Self.key) { values in
                    values[actionID] = binding
                }
                self?.replace(values)
                await self?.postChange()
            } catch {
                pluginShortcutStoreLogger.warning(
                    "Plugin shortcut write failed; reverting projection: \(String(describing: error), privacy: .private)"
                )
                let values = await jsonStore.value(for: Self.key)
                self?.replace(values)
                await self?.postChange()
            }
        }
    }

    /// Removes a user override and restores the manifest default at the next
    /// read. The explicit `.unbound` value should use ``set`` instead.
    func clear(actionID: String) {
        enqueueMutation { [weak self, jsonStore] in
            do {
                let values = try await jsonStore.update(Self.key) { values in
                    values.removeValue(forKey: actionID)
                }
                self?.replace(values)
                await self?.postChange()
            } catch {
                pluginShortcutStoreLogger.warning(
                    "Plugin shortcut clear failed; reverting projection: \(String(describing: error), privacy: .private)"
                )
                let values = await jsonStore.value(for: Self.key)
                self?.replace(values)
                await self?.postChange()
            }
        }
    }

    private func enqueueMutation(
        _ mutation: @escaping @Sendable () async -> Void
    ) {
        lock.lock()
        let predecessor = mutationTail
        let task = Task {
            await predecessor?.value
            guard !Task.isCancelled else { return }
            await mutation()
        }
        mutationTail = task
        lock.unlock()
    }

    private func replace(_ values: [String: CmuxPluginShortcutBinding]) {
        lock.lock()
        rawBindings = values
        lock.unlock()
    }

    @MainActor
    private func postChange() {
        onChange()
    }
}
