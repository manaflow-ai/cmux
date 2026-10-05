public import Foundation
public import UniformTypeIdentifiers

/// What a picker chooses or makes (R89, the cmux picker that replaces
/// every open and save panel): files, folders or either, one or several;
/// or a new file's name and folder (save).
public nonisolated struct PickerMode: Equatable, Sendable {
    public enum Choice: Equatable, Sendable {
        case files
        case folders
        case filesOrFolders
    }

    public enum Kind: Equatable, Sendable {
        case open(Choice)
        case save
    }

    public var kind: Kind
    public var allowsMultiple: Bool
    /// The types the user may choose (open) or save as (save).
    public var filter: PickerFilter
    /// The user switched the filter off ("All Files").
    public var showsAllFiles: Bool

    public init(kind: Kind, allowsMultiple: Bool = false, filter: PickerFilter = .any, showsAllFiles: Bool = false) {
        self.kind = kind
        self.allowsMultiple = allowsMultiple
        self.filter = filter
        self.showsAllFiles = showsAllFiles
    }

    /// One folder (Open Diff Viewer in Folder…).
    public static let folder = PickerMode(kind: .open(.folders))
    /// One file the filter accepts (Open File…, Open Markdown File…).
    public static func file(_ filter: PickerFilter) -> PickerMode { PickerMode(kind: .open(.files), filter: filter) }

    public var isSave: Bool { kind == .save }
    /// Return on a folder chooses it (instead of entering it).
    public var choosesFolders: Bool { kind == .open(.folders) || kind == .open(.filesOrFolders) }

    /// Whether the listing shows the regular file `name` (folders always show).
    public func lists(file name: String) -> Bool {
        switch kind {
        case .open(.folders), .save: false
        case .open: showsAllFiles || filter.accepts(name)
        }
    }

    /// The user can switch between the filter and All Files.
    public var offersAllFiles: Bool { !filter.isAny && filter.allowsAllFiles && kind != .open(.folders) && !isSave }
}

/// The file names a picker lists or saves: by extension, case-insensitive.
/// No extensions: every file. `extensions` keeps the caller's order (the
/// first is the save default); `names` describes them ("Markdown").
public nonisolated struct PickerFilter: Equatable, Sendable {
    public struct FileType: Equatable, Sendable {
        public var name: String
        /// Saved names get the first; open accepts any of them.
        public var extensions: [String]
        /// Uniform types a file's extension may conform to (`public.image`
        /// takes every image extension).
        public var identifiers: [String]

        public init(name: String, extensions: [String], identifiers: [String] = []) {
            self.name = name
            self.extensions = extensions.map { $0.lowercased() }
            self.identifiers = identifiers
        }

        /// A uniform type: its description, its extensions, and itself.
        public init(_ type: UTType) {
            self.init(name: type.localizedDescription ?? type.identifier,
                      extensions: type.tags[.filenameExtension] ?? [], identifiers: [type.identifier])
        }

        func accepts(extension ext: String) -> Bool {
            if extensions.contains(ext) { return true }
            guard !identifiers.isEmpty, let type = UTType(filenameExtension: ext) else { return false }
            return identifiers.contains { identifier in UTType(identifier).map { type.conforms(to: $0) } ?? false }
        }
    }

    public var types: [FileType]
    /// The open picker may offer "All Files" (`PickerMode.offersAllFiles`).
    public var allowsAllFiles: Bool

    public init(types: [FileType], allowsAllFiles: Bool = true) {
        self.types = types
        self.allowsAllFiles = allowsAllFiles
    }

    public static let any = PickerFilter(types: [])
    /// Open Markdown File…: `.md` and `.markdown`.
    public static var markdown: PickerFilter {
        PickerFilter(types: [FileType(name: PickerStrings.markdownType, extensions: ["md", "markdown"])])
    }

    public var isAny: Bool { types.allSatisfy { $0.extensions.isEmpty && $0.identifiers.isEmpty } }

    public func accepts(_ name: String) -> Bool {
        guard !isAny else { return true }
        let ext = (name as NSString).pathExtension.lowercased()
        return !ext.isEmpty && types.contains { $0.accepts(extension: ext) }
    }

    /// "Markdown, Plain Text".
    public var summary: String { types.map(\.name).joined(separator: ", ") }
}

/// Where the picker stands: pure, so every step (enter, up, more)
/// is tested without a file system. The listing of `directory` is read
/// off the main actor (`FolderListing.read`).
public nonisolated struct FolderPickerState: Equatable, Sendable {
    public var mode: PickerMode
    /// The folder listed, standardized, without a trailing slash (but `/`).
    public private(set) var directory: URL
    /// Where the picker opened: its Recent section shows only there.
    public let start: URL
    /// Entries listed per kind (visible, hidden); "Show more" raises it.
    public var limit: Int
    /// The child a step up came from, selected in the parent's list.
    public private(set) var cameFrom: String?
    /// Save: the type the name gets (an index into the filter's types).
    public var saveType: Int = 0

    public static let pageSize = 2_000

    public init(mode: PickerMode, start: URL, limit: Int = Self.pageSize) {
        let directory = Self.normalized(start)
        self.mode = mode
        self.directory = directory
        self.start = directory
        self.limit = limit
        self.cameFrom = nil
    }

    public var isAtStart: Bool { directory == start }
    public var isAtRoot: Bool { directory.path == "/" }

    /// The folder `name` of this one.
    public func entering(_ name: String) -> FolderPickerState { moving(to: directory.appendingPathComponent(name, isDirectory: true)) }

    /// Any folder (a recent one, a typed path).
    public func moving(to folder: URL) -> FolderPickerState {
        var next = self
        next.directory = Self.normalized(folder)
        next.limit = Self.pageSize
        next.cameFrom = nil
        return next
    }

    /// The parent folder, with this folder selected there; nil at `/`.
    public func up() -> FolderPickerState? {
        guard !isAtRoot else { return nil }
        var next = moving(to: directory.deletingLastPathComponent())
        next.cameFrom = directory.lastPathComponent
        return next
    }

    /// The next page of a large folder.
    public func showingMore() -> FolderPickerState {
        var next = self
        next.limit += Self.pageSize
        return next
    }

    /// The filter switched on or off ("All Files").
    public func togglingAllFiles() -> FolderPickerState {
        var next = self
        next.mode.showsAllFiles.toggle()
        return next
    }

    /// The breadcrumb's folders, outermost first: home as `~` when the
    /// folder is under it, else `/` and every folder.
    public func crumbs(home: URL) -> [(title: String, url: URL)] {
        let homePath = Self.normalized(home).path
        let path = directory.path
        var crumbs: [(title: String, url: URL)]
        var current: String
        if path == homePath || path.hasPrefix(homePath + "/") {
            crumbs = [("~", Self.normalized(home))]
            current = homePath
        } else {
            crumbs = [("/", URL(fileURLWithPath: "/", isDirectory: true))]
            current = ""
        }
        for part in path.dropFirst(current.count).split(separator: "/") {
            current += "/" + part
            crumbs.append((String(part), URL(fileURLWithPath: current, isDirectory: true)))
        }
        return crumbs
    }

    /// The path for the breadcrumb, home as `~`: `~ › fun › cmux`.
    public func breadcrumb(home: URL) -> String {
        let path = directory.path
        let homePath = Self.normalized(home).path
        var parts: [String]
        if path == homePath {
            parts = ["~"]
        } else if path.hasPrefix(homePath + "/") {
            parts = ["~"] + path.dropFirst(homePath.count + 1).split(separator: "/").map(String.init)
        } else {
            parts = ["/"] + path.split(separator: "/").map(String.init)
        }
        return parts.joined(separator: " \u{203A} ")
    }

    static func normalized(_ url: URL) -> URL {
        let path = url.standardizedFileURL.path
        let trimmed = path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
        return URL(fileURLWithPath: trimmed.isEmpty ? "/" : trimmed, isDirectory: true)
    }
}
