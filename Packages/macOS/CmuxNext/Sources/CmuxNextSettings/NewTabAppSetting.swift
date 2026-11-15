import Foundation

/// `tabs.newTabApp` in cmux-next.json: the extension (app id, `publisher/name`) that draws the whole
/// New Tab page (`cmux.newtab/1`). Unset (the default) the page is cmux's own, unchanged; the web page
/// also draws its own when the named app is missing, hidden, disabled or its render fails. The native
/// New Tab page (`tabs.nativeNewTabPage`) does not read it.
public nonisolated struct NewTabAppSetting: Sendable {
    public init() {}

    /// Whether `id` can name an app: `publisher/name`, each part non-empty, with no spaces,
    /// control characters or further `/`.
    public static func isValidID(_ id: String) -> Bool {
        let parts = id.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, id.utf8.count <= 200 else { return false }
        return parts.allSatisfy { part in
            !part.isEmpty && !part.unicodeScalars.contains { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) }
        }
    }

    /// The app `root` names, nil when unset or not an app id (the schema check reports it).
    public static func app(in root: JSONValue) -> String? {
        guard let id = root.value(at: configPath)?.stringValue, isValidID(id) else { return nil }
        return id
    }
}

extension CmuxConfigSnapshot {
    /// `tabs.newTabApp`; nil when unset or not an app id.
    public var newTabApp: String? { NewTabAppSetting.app(in: root) }
}
