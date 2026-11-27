import CmuxNextDesign
public import Foundation

/// `sidebar.look`: the sidebar drawn like another app's (`claude`, `codex`, `studio`, `rex`), or cmux's own
/// (`cmux`, the default). A look is data: a shipped file of ordinary public settings
/// (`Resources/sidebar-looks/<look>.json`, the theme-file shape), so a person can rebuild or change
/// any look in cmux-next.json. It fills only the keys that cmux-next.json, the managed layers and the
/// theme file leave unset, so a person's own setting always wins. The Rust reader (cmux-config
/// `sidebar_look`, which the daemon and the CLI use) reads the same files the same way, and its tests
/// hold each shipped file to the grid keys: a look never sets row height, sidebar width, the
/// trailing column or motion, so switching looks moves no pane.
///
/// Swift reads the file (the folder is the app bundle's) and Rust reads the look and fills the root
/// (cmux-config app_ops/effective.rs, `sidebar_look.entries`).
public nonisolated struct SidebarLookPreset {
    public nonisolated init() {}
    public static let folderName = "sidebar-looks"
    /// The look files cmux ships (`<app>/Contents/Resources/sidebar-looks`).
    public static let bundledFolder: URL? = Bundle.main.resourceURL?.appending(path: folderName, directoryHint: .isDirectory)
    /// The look `root` picks when it is one with a file: nil for `cmux` and for an unknown value.
    public static func look(in root: JSONValue) -> String? {
        guard let name = root.value(at: configPath)?.stringValue, name != fallback, values.contains(name) else { return nil }
        return name
    }

    /// Each value look `name`'s file sets, by key path, in key-path order. A value the schema refuses is
    /// skipped (the Rust tests keep the shipped files clean). Empty when there is no file. File I/O.
    public static func entries(of name: String, folder: URL?) -> [(path: [String], value: JSONValue)] {
        guard let text = text(of: name, folder: folder) else { return [] }
        let reply = SettingsRust().answer("sidebar_look.entries", ["name": .string(name), "text": .string(text)])
        return (reply["entries"]?.arrayValue ?? []).compactMap { entry in
            guard let path = entry["path"]?.arrayValue?.compactMap(\.stringValue), let value = entry["value"] else { return nil }
            return (path, value)
        }
    }

    /// `root` with every value of the look it picks whose key `root` leaves unset (unchanged for `cmux`).
    public static func filling(_ root: JSONValue, folder: URL? = bundledFolder) -> JSONValue {
        applying(to: root, folder: folder).root
    }

    /// Keep the inherited group style from the same load, even when the person's file overrides it.
    static func applying(to root: JSONValue, folder: URL?) -> (root: JSONValue, groupBackground: JSONValue?) {
        guard let name = look(in: root) else { return (root, nil) }
        let values = entries(of: name, folder: folder)
        let filled = values.reduce(root) { root, entry in
            root.value(at: entry.path) == nil ? root.setting(entry.value, at: entry.path) : root
        }
        return (filled, values.first { $0.path == SidebarSectionsSetting.groupHeaderBackgroundPath }?.value)
    }

    /// The text of look `name`'s file in `folder`, if it reads.
    private static func text(of name: String, folder: URL?) -> String? {
        guard let url = folder?.appending(path: "\(name).json"), let data = try? Data(blockingContentsOf: url) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}
