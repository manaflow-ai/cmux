import Foundation

/// Which files of a folder a scan lists, and how deep it looks.
///
/// Hidden files (a leading dot, the way `screencapture` writes a file before
/// it renames it into place) are never listed.
///
/// ```swift
/// // The macOS screenshot preview folder: one level of NSIRD_screencaptureui_* folders.
/// FileGridScanRule(kinds: [.image, .video], depth: 1, folderPrefix: "NSIRD_screencaptureui_")
/// ```
public nonisolated struct FileGridScanRule: Sendable, Hashable {
    /// The kinds listed; an empty set lists every kind.
    public var kinds: Set<FileGridMediaKind>
    /// Extensions listed as ``FileGridMediaKind/image`` although the system does not call them images
    /// (Snagit's `snagx`), lowercased, without a dot.
    public var extraImageExtensions: Set<String>
    /// When not empty, only names that start with one of these (QuickTime's "Screen Recording").
    public var namePrefixes: [String]
    /// How many folder levels below the folder are listed too (0: the folder only).
    public var depth: Int
    /// When set, only subfolders whose names start with this are entered.
    public var folderPrefix: String?

    /// Makes a rule.
    ///
    /// - Parameters:
    ///   - kinds: kinds to list; defaults to pictures and movies.
    ///   - extraImageExtensions: more extensions to treat as pictures.
    ///   - namePrefixes: only names with one of these prefixes (empty: any name).
    ///   - depth: subfolder levels to enter.
    ///   - folderPrefix: only subfolders with this name prefix.
    public init(kinds: Set<FileGridMediaKind> = [.image, .video], extraImageExtensions: Set<String> = [],
                namePrefixes: [String] = [], depth: Int = 0, folderPrefix: String? = nil) {
        self.kinds = kinds
        self.extraImageExtensions = extraImageExtensions
        self.namePrefixes = namePrefixes
        self.depth = max(0, depth)
        self.folderPrefix = folderPrefix
    }

    /// The kind a file with this name is listed as, nil when the rule leaves it out.
    ///
    /// - Parameter name: the file name with its extension.
    public func kind(ofFileNamed name: String) -> FileGridMediaKind? {
        guard !name.hasPrefix(".") else { return nil }
        if !namePrefixes.isEmpty, !namePrefixes.contains(where: { name.hasPrefix($0) }) { return nil }
        let ext = (name as NSString).pathExtension.lowercased()
        let kind: FileGridMediaKind = extraImageExtensions.contains(ext) ? .image : FileGridMediaKind(pathExtension: ext)
        guard kinds.isEmpty || kinds.contains(kind) else { return nil }
        return kind
    }

    /// Whether a scan enters a subfolder with this name.
    ///
    /// - Parameter name: the subfolder's name.
    public func entersFolder(named name: String) -> Bool {
        guard !name.hasPrefix(".") else { return false }
        guard let folderPrefix else { return true }
        return name.hasPrefix(folderPrefix)
    }
}
