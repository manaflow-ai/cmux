public import Foundation

/// A flat imported bookmark: title, URL and its folder path from the
/// source's root (the shape `CmuxNextBrowserImport` reads from Chrome,
/// Safari, Firefox and the other browsers).
public nonisolated struct BookmarkImportItem: Sendable, Hashable {
    public var title: String
    public var url: URL
    public var folderPath: [String]
    public var created: Date?

    public init(title: String, url: URL, folderPath: [String], created: Date?) {
        self.title = title
        self.url = url
        self.folderPath = folderPath
        self.created = created
    }
}

/// Where imports land (bookmarks.md section 3 and the onboarding contract):
/// a browser import is one folder per source at the end of the Bookmarks
/// Bar, replaced in place on a re-import; an HTML file is one "Imported"
/// folder there.
public nonisolated enum BookmarkImportPlan {
    /// One browser source's import: the operation and what it holds.
    public nonisolated struct SourceImport: Sendable, Hashable {
        public var operation: BookmarkOperation
        /// Bookmarks the operation creates.
        public var added: Int
        /// Bookmarks left out because the same URL is already in the same folder.
        public var duplicates: Int
    }

    /// The replace-or-create operation for one browser source. Items keep
    /// their order; folders appear in order of first use. When every item
    /// shares the same first folder (the source's bar), that level is dropped.
    public static func source(title: String, sourceKey: String, items: [BookmarkImportItem]) -> BookmarkOperation {
        sourceImport(title: title, sourceKey: sourceKey, items: items).operation
    }

    /// `source(title:sourceKey:items:)` with counts. A bookmark whose URL is
    /// already in the same folder is skipped (decision
    /// BOOKMARKS-IMPORT-EVERY-BROWSER I4); the same URL in another folder stays.
    public static func sourceImport(title: String, sourceKey: String, items: [BookmarkImportItem]) -> SourceImport {
        let shared = items.first?.folderPath.first
        let strip = shared != nil && items.allSatisfy { $0.folderPath.first == shared }
        let paths = items.map { strip ? Array($0.folderPath.dropFirst()) : $0.folderPath }
        let root = Builder()
        var added = 0
        for (item, path) in zip(items, paths) {
            if root.add(.bookmark(item.title, item.url, created: item.created), at: path[...]) { added += 1 }
        }
        let folder = BookmarkDraft.folder(title, root.drafts)
        return SourceImport(operation: .importDrafts(parent: BookmarkRoot.bar.rawValue, index: nil, sourceKey: sourceKey, replace: true,
                                                     drafts: [folder]),
                            added: added, duplicates: items.count - added)
    }

    /// An HTML file into a new folder named `title` at the end of the bar.
    public static func file(_ document: NetscapeBookmarkDocument, title: String, barTitle: String) -> BookmarkOperation {
        .importDrafts(parent: BookmarkRoot.bar.rawValue, index: nil, sourceKey: nil, replace: false,
                      drafts: [.folder(title, document.drafts(barTitle: barTitle))])
    }

    /// An HTML file as the whole tree of an empty profile: the toolbar
    /// folder fills the Bookmarks Bar, the rest Other Bookmarks (the export
    /// round trip).
    public static func restore(_ document: NetscapeBookmarkDocument) -> [BookmarkOperation] {
        var operations: [BookmarkOperation] = []
        if let bar = document.bar, !bar.isEmpty {
            operations.append(.importDrafts(parent: BookmarkRoot.bar.rawValue, index: nil, sourceKey: nil, replace: false, drafts: bar))
        }
        if !document.other.isEmpty {
            operations.append(.importDrafts(parent: BookmarkRoot.other.rawValue, index: nil, sourceKey: nil, replace: false,
                                            drafts: document.other))
        }
        return operations
    }

    /// Folder tree under construction, keeping first-use order.
    private nonisolated final class Builder {
        private nonisolated enum Entry {
            case leaf(BookmarkDraft)
            case folder(String, Builder)
        }

        private var entries: [Entry] = []
        private var urls: Set<String> = []

        /// False when the folder already holds this URL (the draft is skipped).
        @discardableResult
        func add(_ draft: BookmarkDraft, at path: ArraySlice<String>) -> Bool {
            guard let name = path.first else {
                if let url = draft.url, !urls.insert(url.absoluteString).inserted { return false }
                entries.append(.leaf(draft))
                return true
            }
            for case .folder(let title, let child) in entries where title == name {
                return child.add(draft, at: path.dropFirst())
            }
            let child = Builder()
            entries.append(.folder(name, child))
            return child.add(draft, at: path.dropFirst())
        }

        var drafts: [BookmarkDraft] {
            entries.map { entry in
                switch entry {
                case .leaf(let draft): draft
                case .folder(let title, let child): .folder(title, child.drafts)
                }
            }
        }
    }
}
