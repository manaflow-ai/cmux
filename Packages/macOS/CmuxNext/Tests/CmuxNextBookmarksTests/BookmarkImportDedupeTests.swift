import CmuxNextBookmarks
import Foundation
import Testing

/// Import from another browser (BOOKMARKS-IMPORT-EVERY-BROWSER I4): the
/// same URL twice in one folder is kept once, and the folder an import
/// replaced can be put back as it was (the import's undo step).
@Suite struct BookmarkImportDedupeTests {
    private let bar = BookmarkRoot.bar.rawValue

    private func item(_ title: String, _ url: String, _ path: [String]) throws -> BookmarkImportItem {
        BookmarkImportItem(title: title, url: try #require(URL(string: url)), folderPath: path, created: nil)
    }

    @Test func sameURLInOneFolderIsSkippedButKeptInAnother() throws {
        let items = [
            try item("A", "https://a.example/", ["Bar"]),
            try item("A again", "https://a.example/", ["Bar"]),
            try item("A in Work", "https://a.example/", ["Bar", "Work"]),
            try item("B", "https://b.example/", ["Bar", "Work"]),
            try item("B again", "https://b.example/", ["Bar", "Work"]),
        ]
        let plan = BookmarkImportPlan.sourceImport(title: "Imported from Chrome (Work)", sourceKey: "chrome/Profile 1", items: items)
        #expect(plan.added == 3)
        #expect(plan.duplicates == 2)
        var tree = BookmarkTree()
        try tree.apply(plan.operation)
        let folder = try #require(tree.folder(sourceKey: "chrome/Profile 1"))
        #expect(folder.title == "Imported from Chrome (Work)")
        #expect(tree.children(of: folder.id).map(\.title) == ["A", "Work"])
        let work = try #require(tree.children(of: folder.id).first { $0.isFolder })
        #expect(tree.children(of: work.id).map(\.title) == ["A in Work", "B"])
    }

    @Test func replacedFolderComesBackFromItsDraft() throws {
        var tree = BookmarkTree()
        try tree.apply(BookmarkImportPlan.source(title: "Imported from Arc (Personal)", sourceKey: "arc/Default",
                                                 items: [try item("Old", "https://old.example/", ["Personal", "Pinned"])]))
        let folder = try #require(tree.folder(sourceKey: "arc/Default"))
        let before = try #require(tree.draft(of: folder.id))
        let snapshot = tree.children(of: folder.id).map(\.title)
        try tree.apply(BookmarkImportPlan.source(title: "Imported from Arc (Personal)", sourceKey: "arc/Default",
                                                 items: [try item("New", "https://new.example/", [])]))
        #expect(!tree.isBookmarked(URL(string: "https://old.example/")))
        // Undo: the draft replaces the folder in place.
        try tree.apply(.importDrafts(parent: bar, index: nil, sourceKey: "arc/Default", replace: true, drafts: [before]))
        let restored = try #require(tree.folder(sourceKey: "arc/Default"))
        #expect(restored.id == folder.id)
        #expect(tree.children(of: restored.id).map(\.title) == snapshot)
        #expect(tree.isBookmarked(URL(string: "https://old.example/")))
        #expect(!tree.isBookmarked(URL(string: "https://new.example/")))
    }

    @Test func draftKeepsOrderURLsAndDates() throws {
        var tree = BookmarkTree()
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let dated = BookmarkImportItem(title: "Dated", url: try #require(URL(string: "https://dated.example/")), folderPath: ["F"], created: date)
        try tree.apply(BookmarkImportPlan.source(title: "X", sourceKey: "x/1", items: [try item("First", "https://1.example/", []), dated]))
        let folder = try #require(tree.folder(sourceKey: "x/1"))
        let draft = try #require(tree.draft(of: folder.id))
        #expect(draft.title == "X")
        #expect(draft.children.map(\.title) == ["First", "F"])
        #expect(draft.children[1].children.first?.created == date)
        #expect(draft.children[0].url?.host == "1.example")
        #expect(tree.draft(of: "missing") == nil)
    }
}
