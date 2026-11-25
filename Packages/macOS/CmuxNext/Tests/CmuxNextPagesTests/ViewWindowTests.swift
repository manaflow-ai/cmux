import CoreGraphics
@testable import CmuxNextPages
import Foundation
import Testing

/// The view window (``ViewWindow``, `debug.viewWindow`): the page it loads, the look it carries from
/// `cmux-next.json`, and the sizes it takes.
struct ViewWindowTests {
    @Test func loadsTheMockAppOnLoopbackWithNativeChromeLast() throws {
        let url = try #require(ViewWindow.url(port: 4210, look: [], query: [("fixture", "app.window/new-tab")]))
        #expect(url.absoluteString == "http://127.0.0.1:4210/gallery/mock-app.html?fixture=app.window/new-tab&chrome=native")
    }

    @Test func argumentsWinOverTheLookAndNeverChangeTheChrome() throws {
        let url = try #require(ViewWindow.url(port: 4300, look: [("theme", "Nord"), ("accent", "blue")],
                                              query: [("theme", "Dracula"), ("chrome", "web")]))
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(items.map(\.name) == ["accent", "theme", "chrome"])
        #expect(items.map(\.value) == ["blue", "Dracula", "native"])
        #expect(url.host() == "127.0.0.1" && url.port == 4300)
    }

    @Test func theLookTakesTheSystemsSideOfAThemePair() {
        let config: [String: Any] = ["appearance": ["theme": "light:Rose Pine Dawn,dark:Rose Pine", "accent": "theme"]]
        #expect(ViewWindow.lookQuery(config: config, dark: true).map(\.1) == ["Rose Pine", "theme"])
        #expect(ViewWindow.lookQuery(config: config, dark: false).map(\.1) == ["Rose Pine Dawn", "theme"])
        #expect(ViewWindow.side(of: "dark:Nord", dark: false) == "Nord")
        #expect(ViewWindow.side(of: "Nord", dark: true) == "Nord")
    }

    @Test func noConfigOrNoAppearanceIsNoLook() {
        #expect(ViewWindow.lookQuery(config: nil, dark: true).isEmpty)
        #expect(ViewWindow.lookQuery(config: ["appearance": ["theme": "  "]], dark: true).isEmpty)
    }

    @Test func readsTheLookFromAJSON5File() async throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "view-window-\(UUID().uuidString).json")
        try Data("{ appearance: { theme: \"Nord\", }, // a comment\n}".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let look = await ViewWindow.readLook(file, dark: true)
        #expect(look.map(\.0) == ["theme"] && look.map(\.1) == ["Nord"])
        #expect(await ViewWindow.readLook(file.appending(path: "missing"), dark: true).isEmpty)
    }

    @Test func argumentsPlaceTheWindowAndTheRestAreMockAppKeys() {
        let parsed = ViewWindow.parse(["port": "4300", "width": "900", "height": "700", "script": "streaming", "density": "compact"])
        #expect(parsed.port == 4300 && parsed.size == CGSize(width: 900, height: 700))
        #expect(parsed.query.map(\.0) == ["density", "script"])
        let defaults = ViewWindow.parse(["port": "99999"])
        #expect(defaults.port == ViewWindow.defaultPort && defaults.size == CGSize(width: 1280, height: 800) && defaults.query.isEmpty)
        #expect(ViewWindow.parse(["width": "nan", "height": "inf"]).size == CGSize(width: 1280, height: 800))
    }

    @Test func sizesAreClampedLikeTheShells() {
        #expect(ViewWindow.clamped(CGSize(width: 100, height: 9000)) == CGSize(width: 320, height: 5120))
        #expect(ViewWindow.clamped(CGSize(width: 900, height: 700)) == CGSize(width: 900, height: 700))
    }
}
