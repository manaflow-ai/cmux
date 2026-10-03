public import CmuxNextSettings
import Foundation

/// The one write path of `settings.set`, `settings.reset` and
/// `settings.unset` (plans/cmux-next/settings-surfaces.md): schema keys
/// are validated and written through the settings owner, a managed key is
/// refused on every path, and other keys (custom actions, shortcut
/// bindings) keep the raw file write.
extension ControlRouter {
    func writeSetting(_ value: JSONValue?, at path: [String], store: any ControlSettingsStore) async throws {
        let descriptor = SettingsSchema.descriptor(for: path)
        if let descriptor, let value, !descriptor.accepts(value) {
            throw ControlError.invalidParams(String(describing: SettingRefused(key: descriptor.id, value: value)))
        }
        if let writer = settingsWriter {
            if let managed = await writer.managedKey(forPath: path) {
                throw ControlError(code: "managed", message: String(describing: SettingManaged(key: managed.key, source: managed.source)))
            }
            if descriptor != nil {
                do {
                    try await writer.setSetting(at: path, to: value)
                } catch let refused as SettingRefused {
                    throw ControlError.invalidParams(String(describing: refused))
                } catch let managed as SettingManaged {
                    throw ControlError(code: "managed", message: String(describing: managed))
                }
                snapshots.publish { $0.settings = nil }
                return
            }
        }
        if let value { try await store.set(value, at: path) } else { try await store.remove(path) }
        // Read-your-writes: answer from the file until the watcher republishes.
        snapshots.publish { $0.settings = nil }
    }
}
