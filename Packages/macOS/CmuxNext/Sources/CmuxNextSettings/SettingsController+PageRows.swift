// The Settings page's schema rows, shared with its native bridge. Keep the raw stored value
// alongside the effective value so web can distinguish an explicit default from an unset key.
extension SettingsController {
    public func pageRows(section: String?, managedInfo: (ManagedSource) -> JSONValue) -> JSONValue {
        let root = snapshot.root
        return .array(SettingsSchema.all.filter { section == nil || $0.section.rawValue == section }.map { descriptor in
            var row: JSONValue = [
                "key": .string(descriptor.id),
                "value": descriptor.effectiveValue(in: root) ?? .null,
                "stored": descriptor.storedValue(in: fileRoot) ?? .null,
                "default": defaultValue(of: descriptor) ?? .null,
                "customized": .bool(isCustomized(descriptor)),
                "managed": managedSource(for: descriptor).map(managedInfo) ?? .null,
            ]
            if descriptor.path == ChatSettings.rootsPath, case .object(var members) = row {
                members["folders"] = chatRootRows
                members["user_roots"] = fileRoot.value(at: ChatSettings.rootsPath) ?? .array([])
                row = .object(members)
            }
            return row
        })
    }

}
