import CCmuxScreenshots
public import CmuxNextFileGrid
import Foundation

/// Which files of a folder a scan lists, and how deep it looks. The rule itself is Rust's
/// (cmux-screenshots `rule.rs`); this holds its fields and asks it.
///
/// Hidden files (a leading dot, the way `screencapture` writes a file before
/// it renames it into place) are never listed.
///
/// ```swift
/// // The macOS screenshot preview folder: one level of NSIRD_screencaptureui_* folders.
/// ScreenshotScanRule(kinds: [.image, .video], depth: 1, folderPrefix: "NSIRD_screencaptureui_")
/// ```
public nonisolated struct ScreenshotScanRule: Sendable, Hashable {
    /// The kinds listed; an empty set lists every kind.
    public let kinds: Set<FileGridMediaKind>
    /// Extensions listed as ``FileGridMediaKind/image`` although the system does not call them images
    /// (Snagit's `snagx`), lowercased, without a dot.
    public let extraImageExtensions: Set<String>
    /// When not empty, only names that start with one of these (QuickTime's "Screen Recording").
    public let namePrefixes: [String]
    /// How many folder levels below the folder are listed too (0: the folder only).
    public let depth: Int
    /// When set, only subfolders whose names start with this are entered.
    public let folderPrefix: String?
    /// The rule as the C ABI's JSON (what the pane's sources carry).
    let json: String
    private let handle: RustHandle
    /// The Rust rule, live while this value is.
    var pointer: OpaquePointer? { handle.pointer }

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
        let mask = kinds.reduce(UInt32(0)) { $0 | (1 << (ScreenshotsFFI.raw($1) - 1)) }
        var json: [String: Any] = ["kinds": mask, "extraImageExtensions": extraImageExtensions.sorted(),
                                   "namePrefixes": namePrefixes, "depth": self.depth]
        if let folderPrefix { json["folderPrefix"] = folderPrefix }
        self.json = ScreenshotsFFI.json(json)
        handle = RustHandle(ScreenshotsFFI.bytes(self.json) { cmux_screenshots_rule_new($0, $1) }) {
            cmux_screenshots_rule_free($0)
        }
    }

    /// The rule a source's JSON from `cmux_screenshots_detect` names.
    init(json: [String: Any]) {
        let mask = json["kinds"] as? Int ?? 3
        self.init(kinds: mask == 0 ? [] : Set(FileGridMediaKind.allCases.filter { mask & (1 << (Int(ScreenshotsFFI.raw($0)) - 1)) != 0 }),
                  extraImageExtensions: Set(json["extraImageExtensions"] as? [String] ?? []),
                  namePrefixes: json["namePrefixes"] as? [String] ?? [], depth: json["depth"] as? Int ?? 0,
                  folderPrefix: json["folderPrefix"] as? String)
    }

    /// The kind a file with this name is listed as, nil when the rule leaves it out.
    ///
    /// - Parameter name: the file name with its extension.
    public func kind(ofFileNamed name: String) -> FileGridMediaKind? {
        kind(entryKind: 1, hidden: false, name: name)
    }

    /// The kind a directory entry is listed as, nil when the rule leaves it out.
    func kind(entryKind: UInt32, hidden: Bool, name: String) -> FileGridMediaKind? {
        let system = ScreenshotsFFI.systemKind(ofFileNamed: name)
        return ScreenshotsFFI.kind(ScreenshotsFFI.bytes(name) { cmux_screenshots_rule_item_kind(handle.pointer, entryKind, hidden, $0, $1, system) })
    }
}
