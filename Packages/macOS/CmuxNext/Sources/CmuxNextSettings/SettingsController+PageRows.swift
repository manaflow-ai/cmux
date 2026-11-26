// The Settings page's schema rows, shared with its native bridge. Keep the raw stored value
// alongside the effective value so web can distinguish an explicit default from an unset key.
extension SettingsController {
    public func pageRows(section: String?, managedInfo: (ManagedSource) -> JSONValue) -> JSONValue {
        let descriptors = SettingsSchema.all.filter { section == nil || $0.section.rawValue == section }
        // One Rust call reads every row (`schema.rows`): the effective value from the snapshot, the
        // stored one from the person's file.
        let reads = SettingsSchema.reads(root: snapshot.root, storedRoot: fileRoot, keys: descriptors.map(\.id))
        return .array(descriptors.map { descriptor in
            let read = reads[descriptor.id]
            var row: JSONValue = [
                "key": .string(descriptor.id),
                "value": read?.effective ?? .null,
                "stored": read?.stored ?? .null,
                "default": defaultValue(of: descriptor) ?? .null,
                "customized": .bool(isCustomized(descriptor, stored: read?.stored)),
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
