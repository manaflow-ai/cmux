import AppKit
@testable import CmuxNextPages
import Foundation
import Testing

/// An agent chat's pull request link menu offers the target a click does not take (Leo,
/// 2026-11-07: "default open in normal GitHub.com if you want, optionally"): Open on github.com
/// while a click opens the cmux GitHub page, Open in cmux GitHub Page while it opens github.com.
@MainActor struct LinkMenuGitHubPageRowTests {
    private static let pull = URL(string: "https://github.com/manaflow-ai/cmux/pull/1")!

    private static func menu(clickOpensPage: Bool?) -> (LinkMenu, LinkRouter) {
        let router = LinkRouter()
        router.routing = { .fallback }
        router.gitHubPage = { _ in clickOpensPage }
        var menu = LinkMenu(router: router)
        menu.offersGitHubPage = true
        menu.source = "chat-tab"
        return (menu, router)
    }

    @Test func aClickToThePageOffersGitHubDotCom() {
        let (menu, _) = Self.menu(clickOpensPage: true)
        let rows = menu.linkRows(for: Self.pull, browsers: [])
        #expect(rows.first?.kind == .openOnGitHub)
        #expect(rows.first?.title == "Open on github.com")
        #expect(!rows.contains { $0.kind == .openInGitHubPage })
    }

    @Test func aClickToGitHubDotComOffersThePage() {
        let (menu, _) = Self.menu(clickOpensPage: false)
        let rows = menu.linkRows(for: Self.pull, browsers: [])
        #expect(rows.first?.kind == .openInGitHubPage)
        #expect(rows.first?.title == "Open in cmux GitHub Page")
        #expect(!rows.contains { $0.kind == .openOnGitHub })
    }

    @Test func anotherLinkOrSurfaceHasNoGitHubRow() {
        let (menu, _) = Self.menu(clickOpensPage: nil)
        #expect(menu.linkRows(for: Self.pull, browsers: []).map(\.kind) == [.openInCmuxBrowser, .openInNewCmuxTab, .openInDefaultBrowser, .copyLink])
        var terminal = Self.menu(clickOpensPage: true).0
        terminal.offersGitHubPage = false
        #expect(!terminal.linkRows(for: Self.pull, browsers: []).contains { $0.kind == .openOnGitHub })
    }

    @Test func theRowsOpenTheirTargetBesideTheChat() {
        let (menu, router) = Self.menu(clickOpensPage: true)
        var web: [(URL, String?)] = [], page: [(URL, String?)] = []
        router.openInCmux = { url, _, source in web.append((url, source)) }
        router.openGitHubPage = { url, source in page.append((url, source)); return true }
        menu.perform(LinkMenuRow(.openOnGitHub, ""), link: Self.pull, file: nil)
        menu.perform(LinkMenuRow(.openInGitHubPage, ""), link: Self.pull, file: nil)
        #expect(web.map(\.0) == [Self.pull] && web.map(\.1) == ["chat-tab"])
        #expect(page.map(\.0) == [Self.pull] && page.map(\.1) == ["chat-tab"])
        // A page that cannot open (the daemon is away) falls back to github.com.
        router.openGitHubPage = { _, _ in false }
        menu.perform(LinkMenuRow(.openInGitHubPage, ""), link: Self.pull, file: nil)
        #expect(web.count == 2)
    }
}
