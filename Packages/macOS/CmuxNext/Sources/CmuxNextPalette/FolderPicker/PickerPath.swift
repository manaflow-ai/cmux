public import Foundation

/// Path mode (R89): a query that starts with `/` or `~/` is a path typed
/// one segment at a time, not a filter. `~/` means home only here; a `~`
/// alone, or anywhere else, is text to filter by.
public nonisolated struct PickerPath: Equatable, Sendable {
    /// The folder part as typed, up to and with its last `/` (`~/fun/`).
    public let typedFolder: String
    /// The segment after it, being typed (`cm`).
    public let segment: String
    /// `typedFolder` resolved (`~/` is home).
    public let folder: URL

    /// Nil when `query` is not a path.
    public init?(_ query: String, home: URL) {
        guard Self.isPath(query), let slash = query.lastIndex(of: "/") else { return nil }
        typedFolder = String(query[...slash])
        segment = String(query[query.index(after: slash)...])
        let expanded = typedFolder.hasPrefix("~/") ? home.path + String(typedFolder.dropFirst(1)) : typedFolder
        folder = FolderPickerState.normalized(URL(fileURLWithPath: expanded, isDirectory: true))
    }

    public static func isPath(_ query: String) -> Bool { query.hasPrefix("/") || query.hasPrefix("~/") }

    /// The entries of `folder` that complete `segment`: a case-insensitive
    /// prefix, in listing order (folders first, Finder order); dot entries
    /// only for a segment that starts with `.`.
    public func completions(_ entries: [FolderEntry]) -> [FolderEntry] {
        let prefix = segment.lowercased()
        return entries.filter { entry in
            (segment.hasPrefix(".") || !entry.isHidden) && entry.name.lowercased().hasPrefix(prefix)
        }
    }

    /// The query after completing `entry`: a folder ends in `/`, so the next
    /// segment's completions follow.
    public func completing(_ entry: FolderEntry) -> String {
        typedFolder + entry.name + (entry.isDirectory ? "/" : "")
    }
}

/// A place the picker offers at its start (R89, Locations): the focused
/// workspace's folders, home and its standard folders, iCloud Drive when
/// present, and the user's pinned folders (`picker.pinned`).
public nonisolated struct PickerLocation: Equatable, Sendable {
    public enum Kind: String, Equatable, Sendable {
        case workspace, home, desktop, documents, downloads, iCloudDrive, pinned
    }

    public let kind: Kind
    public let url: URL

    public init(kind: Kind, url: URL) {
        self.kind = kind
        self.url = FolderPickerState.normalized(url)
    }

    /// Home, Desktop, Documents, Downloads, then iCloud Drive when the host
    /// says it is there (its folder is not looked into to find out).
    public static func standard(home: URL, iCloudDrive: Bool) -> [PickerLocation] {
        var places = [PickerLocation(kind: .home, url: home)]
        for (kind, name) in [(Kind.desktop, "Desktop"), (.documents, "Documents"), (.downloads, "Downloads")] {
            places.append(PickerLocation(kind: kind, url: home.appendingPathComponent(name, isDirectory: true)))
        }
        if iCloudDrive {
            places.append(PickerLocation(kind: .iCloudDrive,
                                         url: home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)))
        }
        return places
    }

    /// Recent, the workspace's folders, the standard places, then the pinned
    /// ones, each folder once.
    public static func ordered(workspace: [URL], standard: [PickerLocation], pinned: [URL]) -> [PickerLocation] {
        var seen = Set<String>()
        let all = workspace.map { PickerLocation(kind: .workspace, url: $0) } + standard + pinned.map { PickerLocation(kind: .pinned, url: $0) }
        return all.filter { seen.insert($0.url.path).inserted }
    }

    public var symbol: String {
        switch kind {
        case .workspace: "square.stack.3d.up"
        case .home: "house"
        case .desktop: "menubar.dock.rectangle"
        case .documents: "doc"
        case .downloads: "arrow.down.circle"
        case .iCloudDrive: "icloud"
        case .pinned: "pin"
        }
    }
}
