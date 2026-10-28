public import CmuxNextDesignTokens
public import Foundation

/// cmux.json `workspaceGroups`: settings for workspace groups, the shape planned in
/// docs/workspace-groups.md. A group's entry in `byCwd` is found by its anchor's folder (the
/// folder of the group's first workspace):
///
/// ```json
/// "workspaceGroups": {
///   "newWorkspacePlacement": "afterCurrent",
///   "byCwd": {
///     "~/manaflow/cmux": { "color": "#7A4FD8", "icon": "ladybug.fill", "newWorkspacePlacement": "top",
///                         "contextMenu": [{ "action": "newWorkspace", "title": "New Workspace" }] },
///     "~/projects/*": { "icon": "leaf.fill", "newWorkspacePlacement": "end" }
///   }
/// }
/// ```
///
/// A key with `*` or `?` is a glob over the whole folder path; any other key is a folder and
/// matches it and every folder inside it. `~` is the home folder. The longest matching key wins.
public nonisolated struct WorkspaceGroupConfig: Sendable, Hashable {
    /// Where New Workspace in Group puts the new workspace in its group.
    public enum Placement: String, Sendable, Hashable, CaseIterable {
        /// After the group workspace the window shows; the group's top when it shows none.
        case afterCurrent
        /// Right after the group's first workspace.
        case top
        /// After the group's last workspace.
        case end
    }

    /// One row a group's entry adds to its header menu: an action id and an optional title.
    public struct MenuEntry: Sendable, Hashable {
        /// The action the row runs, by catalog id or `actions` name.
        public let action: String
        /// The row's title; nil uses the action's own title.
        public let title: String?

        /// - Parameters:
        ///   - action: The action the row runs.
        ///   - title: The row's title, nil for the action's own.
        public init(action: String, title: String? = nil) {
            self.action = action
            self.title = title
        }
    }

    /// One group's settings (a `byCwd` value). Every member is optional: a missing one leaves the
    /// group's own value.
    public struct Entry: Sendable, Hashable {
        /// The header color: a palette token or `#RRGGBB`.
        public var color: GroupTint?
        /// The header icon: an SF Symbol name or an emoji.
        public var icon: String?
        /// Where New Workspace in Group puts a new workspace.
        public var newWorkspacePlacement: Placement?
        /// Rows the group's header menu adds, in order.
        public var contextMenu: [MenuEntry]

        /// - Parameters: The entry's members; each is absent when nil or empty.
        public init(color: GroupTint? = nil, icon: String? = nil, newWorkspacePlacement: Placement? = nil, contextMenu: [MenuEntry] = []) {
            self.color = color
            self.icon = icon
            self.newWorkspacePlacement = newWorkspacePlacement
            self.contextMenu = contextMenu
        }
    }

    /// The `workspaceGroups` object.
    public static let configPath = ["workspaceGroups"]
    /// `workspaceGroups.byCwd`, the per-group entries.
    public static let byCwdPath = configPath + ["byCwd"]
    /// `workspaceGroups.newWorkspacePlacement`: the placement for a group whose entry names none.
    /// Nil (unset): a new workspace goes after the group's last one, as before this setting.
    public var newWorkspacePlacement: Placement?
    /// The `byCwd` entries by their key as written.
    public var byCwd: [String: Entry]

    /// - Parameters:
    ///   - newWorkspacePlacement: The global placement; nil leaves ``Placement/end``.
    ///   - byCwd: The per-group entries by their key as written.
    public init(newWorkspacePlacement: Placement? = nil, byCwd: [String: Entry] = [:]) {
        self.newWorkspacePlacement = newWorkspacePlacement
        self.byCwd = byCwd
    }

    /// The key and entry for a group whose anchor is in `directory`: the longest matching key, nil
    /// when none matches or the group has no folder.
    ///
    /// - Parameters:
    ///   - directory: The anchor's folder, absolute or `~/...`.
    ///   - home: The home folder `~` stands for.
    public func entry(for directory: String?, home: String = NSHomeDirectory()) -> (key: String, entry: Entry)? {
        guard let directory, let folder = Self.expand(directory, home: home) else { return nil }
        var best: (length: Int, key: String, entry: Entry)?
        for (key, entry) in byCwd {
            guard let pattern = Self.expand(key, home: home), Self.matches(pattern, folder) else { continue }
            if best.map({ pattern.count > $0.length || (pattern.count == $0.length && key < $0.key) }) ?? true {
                best = (pattern.count, key, entry)
            }
        }
        return best.map { ($0.key, $0.entry) }
    }

    /// The placement for a group whose anchor is in `directory`: its entry's, else the global one,
    /// else ``Placement/end``.
    public func placement(for directory: String?, home: String = NSHomeDirectory()) -> Placement {
        entry(for: directory, home: home)?.entry.newWorkspacePlacement ?? newWorkspacePlacement ?? .end
    }

    /// The key a new entry for `directory` takes: the folder with the home folder written as `~`.
    public static func key(for directory: String, home: String = NSHomeDirectory()) -> String {
        let folder = expand(directory, home: home) ?? directory
        if folder == home { return "~" }
        return folder.hasPrefix(home + "/") ? "~" + folder.dropFirst(home.count) : folder
    }

    /// `path` with `~` expanded and no trailing `/`; nil when empty.
    static func expand(_ path: String, home: String) -> String? {
        var text = path.trimmingCharacters(in: .whitespaces)
        if text == "~" { text = home } else if text.hasPrefix("~/") { text = home + text.dropFirst() }
        while text.count > 1, text.hasSuffix("/") { text.removeLast() }
        return text.isEmpty ? nil : text
    }

    /// A glob (`*` any run within a component, `?` one character) matches the whole folder; a
    /// plain folder matches itself and every folder inside it.
    static func matches(_ pattern: String, _ folder: String) -> Bool {
        guard pattern.contains("*") || pattern.contains("?") else {
            return folder == pattern || pattern == "/" || folder.hasPrefix(pattern + "/")
        }
        return fnmatch(pattern, folder, 0) == 0
    }
}
