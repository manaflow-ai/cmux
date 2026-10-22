import Foundation
import Testing
@testable import MessagesLabHome

/// Media safety R8 (leo-workspace#874): a table or plan card is the Chief's text, so its links open
/// like the transcript's. A cmux app link (a plan owner's `cmux://session/…`, a `tab/` link) goes to
/// the host's app-link opener, which only reveals what is open, and never to the system, where it
/// would reopen a closed tab or start a chat tab. A web link goes to the system; any other scheme
/// opens nothing and is not offered.
@MainActor @Suite(.serialized)
struct HomeCardLinkRouteTests {
    private static let appLinks = [
        "cmux://session/01a12408-f0a2-79a0-8c59-cb472f5bb9aa",
        "cmux://tab/tab_0123456789abcdef0123456789abcdef",
        "cmux://workspace/ws_0123456789abcdef0123456789abcdef",
        "cmux://chief/2e448bc2/session/01a12408",
    ]
    private static let inert = [
        "javascript:alert(1)",
        "vscode://file/etc/passwd",
        "x-custom-app://open?cmd=1",
        "ssh://host",
        "https://user:pw@example.com/",
        "file://evil/etc/passwd",
    ]

    @Test func eachLinkHasItsRoute() throws {
        for text in Self.appLinks { #expect(HomeCardLinkTarget.route(try #require(URL(string: text))) == .app, "\(text)") }
        for text in Self.inert { #expect(HomeCardLinkTarget.route(try #require(URL(string: text))) == nil, "\(text)") }
        #expect(HomeCardLinkTarget.route(try #require(URL(string: "https://github.com/manaflow-ai/cmux/pull/1"))) == .system)
        #expect(HomeCardLinkTarget.route(try #require(URL(string: "file:///Users/me/plan.md"))) == .app)
    }

    @Test func anAppLinkGoesToTheHostAndNeverTheSystem() throws {
        let target = HomeCardLinkTarget.shared
        let saved = (target.appLink, target.openSystem)
        defer { (target.appLink, target.openSystem) = saved }
        var app: [URL] = [], system: [URL] = []
        target.appLink = { app.append($0) }
        target.openSystem = { system.append($0) }
        for text in Self.appLinks + Self.inert { target.open(url: try #require(URL(string: text))) }
        #expect(app.map(\.absoluteString) == Self.appLinks)
        #expect(system.isEmpty, "a card link went to the system: \(system)")

        let web = try #require(URL(string: "https://github.com/manaflow-ai/cmux/pull/1"))
        target.open(url: web)
        #expect(system == [web])

        // With no host opener an app link opens nothing, still never the system.
        target.appLink = nil
        target.open(url: try #require(URL(string: Self.appLinks[0])))
        #expect(system == [web])
    }
}
