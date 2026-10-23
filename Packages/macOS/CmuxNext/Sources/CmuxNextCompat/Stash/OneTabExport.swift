import Foundation

/// OneTab's "Export URLs" text: one `url | title` line per tab, groups
/// separated by blank lines. Lines without ` | ` are a bare address. The
/// daemon keeps only http(s) pages and repeats once per group, so the parse
/// keeps every non-empty line and only caps sizes to what `stash.import`
/// accepts (8192-byte addresses, 1024-byte titles, 1000 tabs a group).
public nonisolated struct OneTabExport: Sendable, Equatable {
    /// One group of tabs: one stash once imported.
    public struct Group: Sendable, Equatable {
        public var tabs: [Tab]
    }

    public struct Tab: Sendable, Equatable {
        public var url: String
        public var title: String?
    }

    public let groups: [Group]

    /// Most tabs one imported group takes; a longer group is split.
    public static let maximumTabs = 1_000
    /// Most groups one import takes; the rest are dropped.
    public static let maximumGroups = 1_000

    /// Parses `text` (any line endings).
    public init(parsing text: String) {
        var groups: [Group] = [], current: [Tab] = []
        func close() {
            for start in stride(from: 0, to: current.count, by: Self.maximumTabs) {
                groups.append(Group(tabs: Array(current[start..<min(current.count, start + Self.maximumTabs)])))
            }
            current = []
        }
        for raw in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                close()
                continue
            }
            if let tab = Self.tab(line) { current.append(tab) }
        }
        close()
        self.groups = Array(groups.prefix(Self.maximumGroups))
    }

    /// Every tab of every group.
    public var tabCount: Int { groups.reduce(0) { $0 + $1.tabs.count } }

    /// `title` cut on a character boundary to the daemon's 1024 UTF-8 bytes (it refuses the whole
    /// import over a longer title).
    private static func capped(_ title: String) -> String {
        guard title.utf8.count > 1_024 else { return title }
        var bytes = 0
        return String(title.prefix { character in
            bytes += character.utf8.count
            return bytes <= 1_024
        })
    }

    private static func tab(_ line: String) -> Tab? {
        // `url | ` (an empty title) lost its space to the line trim.
        let line = line.hasSuffix(" |") ? line + " " : line
        let parts = line.split(separator: " | ", maxSplits: 1, omittingEmptySubsequences: false)
        let url = String(parts[0]).trimmingCharacters(in: .whitespaces)
        guard !url.isEmpty, url.utf8.count <= 8_192 else { return nil }
        let title = parts.count > 1 ? Self.capped(String(parts[1]).trimmingCharacters(in: .whitespaces)) : nil
        return Tab(url: url, title: title?.isEmpty == false ? title : nil)
    }
}
