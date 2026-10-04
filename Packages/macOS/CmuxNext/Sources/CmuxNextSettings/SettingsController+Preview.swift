import Foundation

/// Live preview (R93): the palette shows a value before it is written.
/// A preview is client view state (plans/cmux-next/settings-react.md 1): it
/// applies a snapshot with the value in place and never writes
/// cmux-next.json. Leaving restores the loaded snapshot; committing writes
/// the value and the reload keeps the same look.
extension SettingsController {
    /// Shows `value` for `descriptor` (nil previews the default). Refuses a
    /// managed key or a value the schema refuses, returning false.
    @discardableResult
    public func preview(_ descriptor: SettingDescriptor, _ value: JSONValue?) -> Bool {
        guard managedKeys[descriptor.id] == nil else { return false }
        if let value, !descriptor.accepts(value) { return false }
        let root = Self.replacing(descriptor.path, with: value, in: snapshot.root)
        let previewed = CmuxConfigSnapshot.parse(root, validDensities: SettingsApplier.validDensities,
                                                 validMetrics: SettingsApplier.validMetrics,
                                                 configDirectory: file.url.deletingLastPathComponent())
        applier.apply(previewed)
        previewingKey = descriptor.id
        return true
    }

    /// Ends a preview and restores the loaded settings.
    public func endPreview() {
        guard previewingKey != nil else { return }
        previewingKey = nil
        applier.apply(snapshot)
    }

    /// Writes the previewed value. The preview ends without restoring the
    /// old value, so the window keeps the new look until the reload
    /// applies the same value from the file.
    public func commitPreview(_ descriptor: SettingDescriptor, _ value: JSONValue?) async throws {
        do {
            try await setSetting(descriptor, to: value)
        } catch {
            endPreview()
            throw error
        }
        previewingKey = nil
        await reload()
    }

    /// `root` with `path` set to `value` (nil removes it), creating objects
    /// on the way.
    static func replacing(_ path: [String], with value: JSONValue?, in root: JSONValue) -> JSONValue {
        guard let key = path.first else { return value ?? .null }
        var members: [String: JSONValue] = if case .object(let existing) = root { existing } else { [:] }
        if path.count == 1 {
            members[key] = value
        } else {
            members[key] = replacing(Array(path.dropFirst()), with: value, in: members[key] ?? .object([:]))
        }
        return .object(members)
    }
}
