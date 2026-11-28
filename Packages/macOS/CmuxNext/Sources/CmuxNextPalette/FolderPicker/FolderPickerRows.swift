public import Foundation

/// One row of the picker, before it becomes a palette item: pure data, so
/// the order and marking rules are tested without a palette.
public nonisolated struct FolderPickerRow: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// Folder mode: choose the folder listed.
        case useFolder
        case folder
        case file
        /// More entries than one page lists.
        case more(Int)
        /// Why nothing is listed (permission, missing, empty).
        case notice(FolderPickerNotice)
    }

    public let id: String
    public let kind: Kind
    public let url: URL
    public let isDirectory: Bool
    public let isGitRepository: Bool
    public let isHidden: Bool
    /// Opened recently (or holds a recent file): sorted first.
    public let isRecent: Bool

    public var name: String { url.lastPathComponent }

    init(kind: Kind, url: URL, isDirectory: Bool, isGitRepository: Bool = false, isHidden: Bool = false, isRecent: Bool = false) {
        switch kind {
        case .useFolder: id = "use"
        case .folder: id = "dir:" + url.path
        case .file: id = "file:" + url.path
        case .more: id = "more"
        case .notice: id = "notice"
        }
        self.kind = kind
        self.url = url
        self.isDirectory = isDirectory
        self.isGitRepository = isGitRepository
        self.isHidden = isHidden
        self.isRecent = isRecent
    }
}

public nonisolated enum FolderPickerNotice: Equatable, Sendable {
    case permissionDenied
    case notFound
    case empty
    case unreadable
}

public nonisolated struct FolderPickerRows {
    public nonisolated init() {}
    /// The rows of `state` for its listing, in the order of the webviews
    /// reference picker (webviews/src/viewer-empty/pickerModel.ts):
    /// "Use This Folder" first when folders are chosen; then the level's
    /// entries, recent ones first, folders before files, by name in Finder
    /// order (`c2` before `c10`); then "Show more" or a notice. `recents`
    /// are absolute paths (a folder may end in `/`); a recent file also
    /// makes its folder recent.
    public static func make(state: FolderPickerState, listing: FolderListing, recents: [String]) -> [FolderPickerRow] {
        var rows: [FolderPickerRow] = []
        if state.mode.choosesFolders {
            rows.append(FolderPickerRow(kind: .useFolder, url: state.directory, isDirectory: true))
        }
        let recent = recentSet(recents, mode: state.mode)
        let entries = listing.entries.map { entry in
            (entry: entry, url: state.directory.appendingPathComponent(entry.name, isDirectory: entry.isDirectory))
        }
        // The listing is folders first by name already; a stable partition
        // puts the recent ones in front.
        let ordered = entries.filter { recent.contains($0.url.path) } + entries.filter { !recent.contains($0.url.path) }
        rows += ordered.map { entry, url in
            FolderPickerRow(kind: entry.isDirectory ? .folder : .file, url: url, isDirectory: entry.isDirectory,
                            isGitRepository: entry.isGitRepository, isHidden: entry.isHidden, isRecent: recent.contains(url.path))
        }
        if let failure = listing.failure {
            let notice: FolderPickerNotice = switch failure {
            case .permissionDenied: .permissionDenied
            case .notFound, .notAFolder: .notFound
            case .other: .unreadable
            }
            rows.append(FolderPickerRow(kind: .notice(notice), url: state.directory, isDirectory: true))
        } else if listing.remaining > 0 {
            rows.append(FolderPickerRow(kind: .more(listing.remaining), url: state.directory, isDirectory: true))
        } else if listing.entries.allSatisfy(\.isHidden) {
            rows.append(FolderPickerRow(kind: .notice(.empty), url: state.directory, isDirectory: true))
        }
        return rows
    }

    /// The recent paths sorted first: each item, and in a file picker also
    /// its folder. No file system access (a recent may sit in a protected
    /// folder the user has not opened in this picker).
    public static func recentSet(_ paths: [String], mode: PickerMode) -> Set<String> {
        var set = Set<String>()
        for raw in paths {
            let isFolder = raw.hasSuffix("/")
            let path = isFolder && raw.count > 1 ? String(raw.dropLast()) : raw
            set.insert(path)
            if !isFolder, !mode.choosesFolders || mode.kind == .open(.filesOrFolders) {
                set.insert((path as NSString).deletingLastPathComponent)
            }
        }
        return set
    }
}
