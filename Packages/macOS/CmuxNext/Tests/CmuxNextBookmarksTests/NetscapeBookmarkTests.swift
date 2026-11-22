import CmuxNextBookmarks
import Foundation
import Testing

@Suite struct NetscapeBookmarkTests {
    private let bar = BookmarkRoot.bar.rawValue
    private let other = BookmarkRoot.other.rawValue

    /// A Chrome export, trimmed: toolbar folder, nested folder, entities,
    /// lowercase tags and a missing `</DL>` for the last folder.
    private let chromeExport = """
    <!DOCTYPE NETSCAPE-Bookmark-file-1>
    <!-- This is an automatically generated file. -->
    <META HTTP-EQUIV="Content-Type" CONTENT="text/html; charset=UTF-8">
    <TITLE>Bookmarks</TITLE>
    <H1>Bookmarks</H1>
    <DL><p>
        <DT><H3 ADD_DATE="1600000000" LAST_MODIFIED="0" PERSONAL_TOOLBAR_FOLDER="true">Bookmarks bar</H3>
        <DL><p>
            <DT><A HREF="https://github.com/" ADD_DATE="1600000001" ICON="data:image/png;base64,AAAA">GitHub</A>
            <DT><H3 ADD_DATE="1600000002">Docs &amp; Notes</H3>
            <DL><p>
                <DT><A HREF="https://example.com/?a=1&amp;b=2">Q &lt;1&gt; &#39;x&#39;</A>
            </DL><p>
        </DL><p>
        <dt><a href="https://other.com">Other one</a>
        <DT><H3>Unclosed</H3>
        <DL><p>
            <DT><A HREF="https://last.com">Last</A>
    """

    @Test func readsChromeExport() throws {
        let document = NetscapeBookmarkReader.read(chromeExport)
        let bar = try #require(document.bar)
        #expect(bar.map(\.title) == ["GitHub", "Docs & Notes"])
        #expect(bar[0].url?.absoluteString == "https://github.com/")
        #expect(bar[0].created == Date(timeIntervalSince1970: 1_600_000_001))
        #expect(bar[1].children.first?.title == "Q <1> 'x'")
        #expect(bar[1].children.first?.url?.absoluteString == "https://example.com/?a=1&b=2")
        #expect(document.other.map(\.title) == ["Other one", "Unclosed"])
        #expect(document.other[1].children.map(\.title) == ["Last"])
        #expect(document.count == 6)
    }

    @Test func skipsEntriesWithoutAUsableURL() {
        let html = "<DL><p><DT><A HREF=\"\">Empty</A><DT><A>No href</A><DT><A HREF=\"not a url\">Bad</A><DT><A HREF=\"https://ok.com\">OK</A></DL>"
        #expect(NetscapeBookmarkReader.read(html).other.map(\.title) == ["OK"])
    }

    @Test func roundTripsATree() throws {
        var tree = BookmarkTree()
        let created = Date(timeIntervalSince1970: 1_700_000_000)
        try tree.apply(.create(.bookmark("A & B", url: URL(string: "https://a.com/?x=1&y=2")!, in: bar, id: "a", created: created), index: nil))
        try tree.apply(.create(.folder("Folder \"quoted\"", in: bar, id: "f", created: created), index: nil))
        try tree.apply(.create(.bookmark("<Inner>", url: URL(string: "https://inner.com")!, in: "f", id: "i", created: created), index: nil))
        try tree.apply(.create(.folder("Empty", in: "f", id: "e", created: created), index: nil))
        try tree.apply(.create(.bookmark("Other", url: URL(string: "https://other.com")!, in: other, id: "o", created: created), index: nil))
        try tree.apply(.create(.bookmark("", url: URL(string: "https://untitled.com")!, in: other, id: "u", created: created), index: nil))

        let html = NetscapeBookmarkWriter.write(tree, barTitle: "Bookmarks Bar")
        var restored = BookmarkTree()
        for operation in BookmarkImportPlan.restore(NetscapeBookmarkReader.read(html)) { try restored.apply(operation) }

        func shape(_ tree: BookmarkTree) -> [String] {
            tree.ordered.map { node in
                "\(tree.folderPath(of: node.id).joined(separator: "/"))|\(node.kind)|\(node.title)|\(node.url?.absoluteString ?? "")|\(Int(node.created.timeIntervalSince1970))"
            }
        }
        #expect(shape(restored) == shape(tree))
    }

    @Test func fileImportGoesIntoOneFolderAtTheEndOfTheBar() throws {
        var tree = BookmarkTree()
        try tree.apply(.create(.bookmark("Mine", url: URL(string: "https://mine.com")!, in: bar, id: "mine"), index: nil))
        let document = NetscapeBookmarkReader.read(chromeExport)
        try tree.apply(BookmarkImportPlan.file(document, title: "Imported", barTitle: "Bookmarks Bar"))
        #expect(tree.children(of: bar).map(\.title) == ["Mine", "Imported"])
        let imported = try #require(tree.children(of: bar).last)
        #expect(tree.children(of: imported.id).map(\.title) == ["Bookmarks Bar", "Other one", "Unclosed"])
        #expect(tree.count == 1 + 1 + 1 + document.count)
    }
}
