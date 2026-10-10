public import Foundation

/// The editor sheet's fields (add or edit a bookmark or folder).
public struct BookmarkEditorState: Identifiable, Equatable, Sendable {
    public enum Mode: Equatable, Sendable {
        case addBookmark
        case addFolder
        case edit(String)
    }

    public var id: String {
        switch mode {
        case .addBookmark: "add-bookmark"
        case .addFolder: "add-folder"
        case .edit(let node): node
        }
    }

    public var mode: Mode
    public var title: String
    public var url: String
    public var folder: String
    public var isFolder: Bool
}

/// `cmux://bookmarks`, the manager page's address.
public nonisolated enum BookmarkPageAddress {
    public static let string = "cmux://bookmarks"
    public static var url: URL { URL(string: string)! }

    /// `cmux://bookmarks`, with or without a trailing slash, query or fragment.
    public static func matches(_ url: URL?) -> Bool {
        guard let url, url.scheme?.lowercased() == "cmux" else { return false }
        return url.host()?.lowercased() == "bookmarks"
    }
}
