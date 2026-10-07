import Foundation

/// The viewers' recent folders and files (R89), in one place: the cmux
/// picker sorts them first, the file viewer's empty screen lists recent
/// files, and the webviews empty screens read them through the host ops
/// `cmux.diff.recents {}` and `cmux.markdown.recents {}` (``hostOpValue(_:home:)``,
/// shape in plans/cmux-next/diff-host.md, "Empty state":
/// `{home, items: [{path, name, openedAt, source?, branch?}]}`, `openedAt`
/// in ms since the epoch). Every open records, from any entrypoint: the
/// palette, the CLI, the File menu, the empty screens.
///
/// One user default (`viewer.recents.v1`), JSON `{"diff": [Entry], "markdown": [...], "file": [...]}`,
/// newest first, at most ``limit`` per kind. In what the picker reads a
/// folder's path ends in `/`, so it tells folders from files without
/// touching a protected folder.
@MainActor
final class ViewerRecents {
    enum Kind: String, CaseIterable, Codable, Sendable {
        /// Folders the diff viewer opened: read from the diff host's own
        /// store (`DiffRecents`), never recorded here.
        case diff
        /// Markdown files.
        case markdown
        /// Any file the file viewer opened.
        case file

        var isFolder: Bool { self == .diff }
    }

    struct Entry: Codable, Equatable, Sendable {
        var path: String
        /// Milliseconds since the epoch.
        var openedAt: Double
        /// Diff only: the last source kind (`branch`, `uncommitted`, `staged`, `unstaged`).
        var source: String?
        /// Diff only: the branch when it opened.
        var branch: String?
    }

    static let limit = 20
    private let defaults: UserDefaults
    private let key: String
    private let now: () -> Date
    private var entries: [Kind: [Entry]]

    init(defaults: UserDefaults = .standard, key: String = "viewer.recents.v1", now: @escaping () -> Date = { Date() }) {
        self.defaults = defaults
        self.key = key
        self.now = now
        let data = defaults.data(forKey: key)
        let decoded = data.flatMap { try? JSONDecoder().decode([String: [Entry]].self, from: $0) } ?? [:]
        entries = Dictionary(uniqueKeysWithValues: Kind.allCases.map { ($0, decoded[$0.rawValue] ?? []) })
    }

    /// Paths of `kind`, newest first.
    func paths(_ kind: Kind) -> [String] { (entries[kind] ?? []).map(\.path) }

    /// What the picker lists as recent for `kinds`, newest first: folder
    /// paths end in `/`.
    func pickerPaths(_ kinds: [Kind]) -> [String] {
        kinds.flatMap { kind in (entries[kind] ?? []).map { (entry: $0, folder: kind.isFolder) } }
            .sorted { $0.entry.openedAt > $1.entry.openedAt }
            .map { $0.folder ? $0.entry.path + "/" : $0.entry.path }
    }

    /// `url` was opened as `kind`: it moves to the front. A diff keeps its
    /// last `source` and `branch` unless new ones are given.
    func record(_ url: URL, as kind: Kind, source: String? = nil, branch: String? = nil) {
        let path = url.standardizedFileURL.path
        let previous = entries[kind]?.first { $0.path == path }
        var list = (entries[kind] ?? []).filter { $0.path != path }
        list.insert(Entry(path: path, openedAt: (now().timeIntervalSince1970 * 1_000).rounded(),
                          source: source ?? previous?.source, branch: branch ?? previous?.branch), at: 0)
        entries[kind] = Array(list.prefix(Self.limit))
        save()
    }

    func remove(_ path: String, from kind: Kind) {
        entries[kind]?.removeAll { $0.path == path }
        save()
    }

    /// The answer of `cmux.diff.recents` (`.diff`) or `cmux.markdown.recents`
    /// (`.markdown`): `{home, items: [{path, name, openedAt, source?, branch?}]}`.
    func hostOpValue(_ kind: Kind, home: String = NSHomeDirectory()) -> [String: Any] {
        let items: [[String: Any]] = (entries[kind] ?? []).map { entry in
            var item: [String: Any] = ["path": entry.path, "name": (entry.path as NSString).lastPathComponent,
                                       "openedAt": entry.openedAt]
            if let source = entry.source { item["source"] = source }
            if let branch = entry.branch { item["branch"] = branch }
            return item
        }
        return ["home": home, "items": items]
    }

    private func save() {
        let encoded = Dictionary(uniqueKeysWithValues: entries.map { ($0.key.rawValue, $0.value) })
        if let data = try? JSONEncoder().encode(encoded) { defaults.set(data, forKey: key) }
    }
}
