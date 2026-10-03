public import CmuxNextSettings
import Foundation

/// The one write path of `settings.set`, `settings.reset` and
/// `settings.unset` (plans/cmux-next/settings-surfaces.md): schema keys
/// are validated and written through the settings owner, a managed key is
/// refused on every path, and other keys (custom actions, shortcut
/// bindings) keep the raw file write.
extension ControlRouter {
    func writeSetting(_ value: JSONValue?, at path: [String], store: any ControlSettingsStore) async throws {
        if let value { try await store.set(value, at: path) } else { try await store.remove(path) }
        // Read-your-writes: answer from the file until the watcher republishes.
        snapshots.publish { $0.settings = nil }
    }
}
