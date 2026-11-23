@testable import CmuxNextPages
import Foundation
import Testing

/// An app's entry may sit in a folder of its root (`ui/index.html`, valid per the manifest and
/// listed so by the daemon). The page loads at that path, so its relative links resolve in that
/// folder, and that file is what its root serves. Base red: any entry with a `/` was silently
/// replaced with `index.html`, so such a page showed nothing (#43033 review).
struct PageNestedEntryTests {
    @Test func aNestedEntryIsThePagesDocument() throws {
        let page = try PageDescriptor.appPage(id: "local.web-pane", resource: "web", namespaces: ["local.web-pane."],
                                              entry: "ui/index.html")
        #expect(page.entry == "ui/index.html")
        let url = page.url(route: "#/list")
        #expect(url.absoluteString == "cmux-page://local.web-pane/ui/index.html#/list")
        #expect(page.isEntryDocument(url))
        #expect(page.isEntryDocument(try #require(URL(string: "cmux-page://local.web-pane/"))))
        #expect(!page.isEntryDocument(try #require(URL(string: "cmux-page://local.web-pane/index.html"))))

        let root = URL(fileURLWithPath: "/tmp/pkg/web", isDirectory: true)
        let served = { (url: URL) in PageSchemeHandler.fileURL(for: url, page: page, root: root)?.path ?? "" }
        #expect(served(url).hasSuffix("/pkg/web/ui/index.html"), "\(served(url))")
        #expect(served(try #require(URL(string: "cmux-page://local.web-pane/"))).hasSuffix("/pkg/web/ui/index.html"))
        // A relative asset of the entry resolves inside its folder.
        let asset = try #require(URL(string: "app.js", relativeTo: url)?.absoluteURL)
        #expect(served(asset).hasSuffix("/pkg/web/ui/app.js"), "\(served(asset))")
    }

    @Test func anEntryThatIsNotAFileInsideTheRootIsTheDefault() {
        for entry in ["", "/ui/index.html", "../index.html", "ui/../index.html", "ui//index.html", "ui/", ".hidden/index.html",
                      "ui/.index.html", "ui\\index.html", "."] {
            let page = PageDescriptor(id: "local.web-pane", resource: "web", namespaces: [], entry: entry)
            #expect(page.entry == "index.html", "\(entry)")
            #expect(page.url().path == "/", "\(entry)")
        }
        #expect(PageDescriptor(id: "local.web-pane", resource: "web", namespaces: [], entry: "page.html").url().path == "/")
    }
}
