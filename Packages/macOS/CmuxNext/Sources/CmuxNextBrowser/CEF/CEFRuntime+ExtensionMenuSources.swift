import Foundation

extension CEFRuntime {
    /// The enabled extensions of `browser`'s profile that may have added page
    /// menu rows, for ``BrowserExtensionMenuIcons``. One fork call per menu
    /// that has extension rows; each manifest is read once per version.
    func extensionMenuSources(browser: Int32) -> [BrowserExtensionMenuSource] {
        guard let shim else { return [] }
        let infos: [BrowserExtensionInfo] = forkAPIVersion >= 3
            ? BrowserExtensionInfo.decodeList(shim.takeString(shim.extList(browser)) ?? "[]")
            : BrowserExtensionInfo.fromActions(
                CEFExtensionAction.decodeList(shim.takeString(shim.extActions(browser, CEFExtensionAction.iconPixels)) ?? "[]"))
        return infos.filter { $0.isEnabled && !$0.isTerminated }.map { info in
            let key = "\(info.id)\u{1}\(info.version)\u{1}\(info.path)\u{1}\(info.name)"
            if let cached = extensionMenuSourceCache[key] { return cached }
            var source = info.path.isEmpty
                ? BrowserExtensionMenuSource(id: info.id, name: info.name)
                : BrowserExtensionMenuSource(id: info.id, name: info.name, folder: URL(fileURLWithPath: info.path))
            // The fork's own pick (its largest icon) when the manifest gave none.
            if source.icon1x == nil, source.icon2x == nil, let icon = info.iconPath, !icon.isEmpty {
                source.icon1x = icon
                source.icon2x = icon
            }
            extensionMenuSourceCache[key] = source
            return source
        }
    }
}
