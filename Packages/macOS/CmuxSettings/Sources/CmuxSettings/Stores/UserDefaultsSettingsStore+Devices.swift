import Foundation

extension UserDefaultsSettingsStore {
    /// Changes one physical Mac's sidebar visibility without losing concurrent edits.
    /// Invalid identifiers leave the stored preference unchanged.
    ///
    /// - Parameters:
    ///   - deviceID: The physical Mac's registry UUID.
    ///   - hidden: Whether all of that Mac's builds should be hidden in My Devices.
    public func setMacHidden(deviceID: String, hidden: Bool) {
        guard let id = UUID(uuidString: deviceID)?.uuidString.lowercased() else { return }
        let key = DevicesCatalogSection().hiddenMacIDs
        var ids = Set(value(for: key).compactMap { UUID(uuidString: $0)?.uuidString.lowercased() })
        if hidden { ids.insert(id) } else { ids.remove(id) }
        set(ids.sorted(), for: key)
    }
}
