import Foundation

/// Finder's names for new items: "untitled folder 2", "report copy.txt",
/// "report copy 2.txt", and "report 2.txt" for Keep Both.
public struct FileNamer: Sendable {
    /// How a free name is made from a taken one.
    public enum Style: Sendable {
        /// `name`, `name 2`, `name 3` (new folders, Keep Both).
        case number
        /// `name copy`, `name copy 2` (Duplicate).
        case copy
        /// `name.ext alias`, `name.ext alias 2` (Make Alias: the word goes after the whole name).
        case alias
    }

    /// The word Duplicate adds ("copy"; localized by the caller).
    public var copyWord: String

    /// The word Make Alias adds ("alias"; localized by the caller).
    public var aliasWord: String

    /// Makes a namer. The words default to English, as Finder writes them on an English system.
    public init(copyWord: String = "copy", aliasWord: String = "alias") {
        self.copyWord = copyWord
        self.aliasWord = aliasWord
    }

    /// The first free name for `name` in `style`, given the names already taken.
    /// The extension stays last: "a.txt" becomes "a copy.txt". For ``Style/number``
    /// a free `name` is returned as is.
    public func freeName(for name: String, style: Style, taken: Set<String>) -> String {
        let ns = name as NSString
        let ext = ns.pathExtension
        let stem = ext.isEmpty ? name : ns.deletingPathExtension
        let suffix = ext.isEmpty ? "" : "." + ext
        switch style {
        case .number:
            if !taken.contains(name) { return name }
            var n = 2
            while taken.contains("\(stem) \(n)\(suffix)") { n += 1 }
            return "\(stem) \(n)\(suffix)"
        case .copy:
            let first = "\(stem) \(copyWord)\(suffix)"
            if !taken.contains(first) { return first }
            var n = 2
            while taken.contains("\(stem) \(copyWord) \(n)\(suffix)") { n += 1 }
            return "\(stem) \(copyWord) \(n)\(suffix)"
        case .alias:
            let first = "\(name) \(aliasWord)"
            if !taken.contains(first) { return first }
            var n = 2
            while taken.contains("\(first) \(n)") { n += 1 }
            return "\(first) \(n)"
        }
    }

    /// Whether `name` can be an item name: not empty, not `.` or `..`, no `/`
    /// or NUL, at most 255 UTF-8 bytes.
    public func isValid(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\u{0}")
            && name.utf8.count <= 255
    }
}
