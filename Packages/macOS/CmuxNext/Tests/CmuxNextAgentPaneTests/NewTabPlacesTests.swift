@testable import CmuxNextAgentPane
@testable import CmuxNextDaemon
import Testing

/// ``NewTabPlaces`` without the app: how one tab reads as a bar row, and how folders shorten.
@MainActor
struct NewTabPlacesPackageTests {
    private let places = NewTabPlaces(home: "/Users/you")

    private func tab(_ kind: TabKind, title: String = "", url: String? = nil, cwd: String? = nil, surface: UInt64) -> TabModel {
        TabModel(TabSnapshot(surface: SurfaceID(rawValue: surface), kind: kind, title: title, url: url, cwd: cwd))
    }

    @Test func foldersUnderHomeReadWithATilde() {
        #expect(places.abbreviated("/Users/you") == "~")
        #expect(places.abbreviated("/Users/you/src/cmux") == "~/src/cmux")
        #expect(places.abbreviated("/Users/youth/src") == "/Users/youth/src")
        #expect(places.abbreviated("/opt/tools") == "/opt/tools")
    }

    @Test func addressesDropTheirSchemeWwwAndTrailingSlash() {
        #expect(NewTabPlaces.displayURL("https://www.vite.dev/guide/") == "vite.dev/guide")
        #expect(NewTabPlaces.displayURL("http://localhost:3000/") == "localhost:3000")
    }

    @Test func aBlankBrowserIsNoPlaceAndANamedOneShowsItsAddress() throws {
        #expect(places.place(tab(.browser, title: "Home", url: "about:blank", surface: 9001)) == nil)
        let docs = try #require(places.place(tab(.browser, title: "Vite Guide", url: "https://vite.dev/guide/", surface: 9002)))
        #expect(docs.kind == .browser && docs.title == "Vite Guide" && docs.detail == "vite.dev/guide")
        let shell = try #require(places.place(tab(.pty, title: "/Users/you/src", cwd: "/Users/you/src", surface: 9003)))
        #expect(shell.kind == .terminal && shell.title == "~/src" && shell.detail == nil)
    }
}
