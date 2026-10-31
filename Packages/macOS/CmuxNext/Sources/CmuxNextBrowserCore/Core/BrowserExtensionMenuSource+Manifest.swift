public import Foundation

extension BrowserExtensionMenuSource {
    /// The source for an installed extension `id` named `name` whose files are
    /// in `folder`, from its `manifest.json`. An unreadable manifest gives a
    /// source with no icon that may add rows.
    ///
    /// Chrome picks the menu icon the same way (`ExtensionIconManager`): the
    /// manifest `icons` entry of the smallest size at least 16 px for 1x and
    /// 32 px for 2x, else the largest one.
    public init(id: String, name: String, folder: URL, fileManager: FileManager = .default) {
        let manifestURL = folder.appendingPathComponent("manifest.json")
        guard let data = fileManager.contents(atPath: manifestURL.path),
              let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            self.init(id: id, name: name)
            return
        }
        self.init(id: id, name: name, manifest: manifest, folder: folder, fileManager: fileManager)
    }

    /// Pure apart from reading `_locales` for a `__MSG_…__` short name.
    package init(id: String, name: String, manifest: [String: Any], folder: URL, fileManager: FileManager) {
        var sizes: [(Int, String)] = []
        for (key, value) in manifest["icons"] as? [String: Any] ?? [:] {
            guard let size = Int(key), let file = value as? String, !file.isEmpty else { continue }
            sizes.append((size, folder.appendingPathComponent(file.hasPrefix("/") ? String(file.dropFirst()) : file).path))
        }
        sizes.sort { $0.0 < $1.0 }
        func pick(_ minimum: Int) -> String? { (sizes.first { $0.0 >= minimum } ?? sizes.last)?.1 }
        let permissions = (manifest["permissions"] as? [Any] ?? []).compactMap { $0 as? String }
        let shortName = (manifest["short_name"] as? String).flatMap {
            localizedManifestString($0, manifest: manifest, folder: folder, fileManager: fileManager)
        }
        self.init(id: id, name: name, shortName: shortName, icon1x: pick(16), icon2x: pick(32),
                  mayAddMenuItems: permissions.contains("contextMenus") || permissions.contains("menus"))
    }
}

/// `value`, or its message from the default locale when it is `__MSG_name__`.
private func localizedManifestString(_ value: String, manifest: [String: Any], folder: URL,
                                     fileManager: FileManager) -> String? {
    guard value.hasPrefix("__MSG_"), value.hasSuffix("__"), value.count > 8 else { return value.isEmpty ? nil : value }
    let key = String(value.dropFirst(6).dropLast(2)).lowercased()
    guard let locale = manifest["default_locale"] as? String,
          let data = fileManager.contents(atPath: folder.appendingPathComponent("_locales/\(locale)/messages.json").path),
          let messages = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
    let entry = messages.first { $0.key.lowercased() == key }?.value as? [String: Any]
    return (entry?["message"] as? String).flatMap { $0.isEmpty ? nil : $0 }
}
