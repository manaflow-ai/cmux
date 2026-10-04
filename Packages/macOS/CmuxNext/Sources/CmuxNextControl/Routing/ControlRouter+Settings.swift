public import CmuxNextSettings
import Foundation

/// The one write path of `settings.set`, `settings.reset` and
/// `settings.unset` (plans/cmux-next/settings-surfaces.md): schema keys
/// are validated and written through the settings owner, a managed key is
/// refused on every path, and other keys (custom actions, shortcut
/// bindings) keep the raw file write.
extension ControlRouter {
    func writeSetting(_ value: JSONValue?, at path: [String], store: any ControlSettingsStore, call: ControlCall) async throws {
        var writer = try ControlSettingsPolicy.writer(call)
        if value != nil, SettingsSchema.isRetired(path) {
            throw ControlError(code: "removed", message: String(describing: SettingRetired(key: path.joined(separator: "."))))
        }
        let descriptor = SettingsSchema.descriptor(for: path)
        if let descriptor, let value, !descriptor.accepts(value) {
            throw ControlError.invalidParams(String(describing: SettingRefused(key: descriptor.id, value: value)))
        }
        if let owner = settingsWriter {
            if let managed = await owner.managedKey(forPath: path) {
                throw ControlError(code: "managed", message: String(describing: SettingManaged(key: managed.key, source: managed.source)))
            }
            if let descriptor, !writer.mayWrite(descriptor) {
                guard call.params["confirm"]?.boolValue == true else { throw ControlSettingsPolicy.userOnly(descriptor.id) }
                guard await owner.confirmUserOnlyWrite(key: descriptor.id, value: value) else {
                    throw ControlSettingsPolicy.declined(descriptor.id)
                }
                writer = .user
            }
            if descriptor != nil {
                do {
                    try await owner.setSetting(at: path, to: value, by: writer)
                } catch let refused as SettingRefused {
                    throw ControlError.invalidParams(String(describing: refused))
                } catch let managed as SettingManaged {
                    throw ControlError(code: "managed", message: String(describing: managed))
                } catch let userOnly as SettingUserOnly {
                    throw ControlSettingsPolicy.userOnly(userOnly.key)
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
