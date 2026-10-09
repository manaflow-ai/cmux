import AppKit
import Foundation
import Testing
import WebKit
@testable import CmuxNextAgentPane

/// The agent pane's context menu (cx-k9go): WebKit's default menu (Reload, Look Up, Back...) never
/// shows. Copy stays on a selection, Copy Message and Copy as Markdown act on the message the page
/// reported under the pointer, Fork from Here forks its turn, and Inspect Element stays only in
/// builds with developer tools.
@MainActor
@Suite struct AgentPaneContextMenuTests {
    /// A menu as WebKit builds it for a right-click on selected text.
    static func webKitMenu() -> NSMenu {
        let menu = NSMenu()
        for id in ["WKMenuItemIdentifierCopy", "WKMenuItemIdentifierLookUp", "WKMenuItemIdentifierReload",
                   "WKMenuItemIdentifierGoBack", "WKMenuItemIdentifierShareMenu", "WKMenuItemIdentifierInspectElement"] {
            let item = NSMenuItem(title: id, action: nil, keyEquivalent: "")
            item.identifier = NSUserInterfaceItemIdentifier(id)
            menu.addItem(item)
            menu.addItem(.separator())
        }
        return menu
    }

    /// Runs an item as a click does (its target and action), with no app event loop.
    static func choose(_ item: NSMenuItem) {
        _ = (item.target as? NSObject)?.perform(item.action, with: item)
    }

    static func titles(_ menu: NSMenu) -> [String] {
        menu.items.map { $0.isSeparatorItem ? "-" : $0.title }
    }

    static let reply = AgentPaneMessageTarget(text: "Done. See the diff.", markdown: "**Done.** See the `diff`.", forkSeq: 7)

    private func rebuilt(target: AgentPaneMessageTarget?, devTools: Bool) -> (NSMenu, copies: () -> [String], forks: () -> [Int]) {
        let menu = Self.webKitMenu()
        var copies: [String] = []
        var forks: [Int] = []
        AgentPaneContextMenu.rebuild(menu, target: target, devTools: devTools,
                                     actions: .init(copy: { copies.append($0) }, fork: { forks.append($0) }, openImage: {}))
        return (menu, { copies }, { forks })
    }

    @Test func anAgentReplyOffersCopiesAndForkInMacOrder() {
        let (menu, _, _) = rebuilt(target: Self.reply, devTools: false)
        #expect(Self.titles(menu) == ["WKMenuItemIdentifierCopy", AgentPaneMenuStrings.copyMessage, AgentPaneMenuStrings.copyAsMarkdown,
                                      "-", AgentPaneMenuStrings.forkFromHere])
    }

    @Test func releaseBuildsNeverShowReloadOrInspect() {
        let (menu, _, _) = rebuilt(target: nil, devTools: false)
        #expect(Self.titles(menu) == ["WKMenuItemIdentifierCopy"])
    }

    @Test func devBuildsKeepInspectElementLast() {
        let (menu, _, _) = rebuilt(target: Self.reply, devTools: true)
        #expect(Self.titles(menu).suffix(2) == ["-", "WKMenuItemIdentifierInspectElement"])
        #expect(!Self.titles(menu).contains("WKMenuItemIdentifierReload"))
    }

    @Test func aPromptHasNoMarkdownCopyAndAnUnforkableTurnNoFork() {
        let (menu, _, _) = rebuilt(target: AgentPaneMessageTarget(text: "fix the build"), devTools: false)
        #expect(Self.titles(menu) == ["WKMenuItemIdentifierCopy", AgentPaneMenuStrings.copyMessage])
    }

    /// Right-click in the composer: WebKit's Cut, Copy and Paste stay, its other items go.
    @Test func theComposerKeepsCutCopyAndPaste() {
        let menu = NSMenu()
        for id in ["WKMenuItemIdentifierCut", "WKMenuItemIdentifierCopy", "WKMenuItemIdentifierPaste",
                   "WKMenuItemIdentifierSpellingMenu", "WKMenuItemIdentifierReload"] {
            let item = NSMenuItem(title: id, action: nil, keyEquivalent: "")
            item.identifier = NSUserInterfaceItemIdentifier(id)
            menu.addItem(item)
        }
        AgentPaneContextMenu.rebuild(menu, target: nil, devTools: false, actions: .init(copy: { _ in }, fork: { _ in }, openImage: {}))
        #expect(Self.titles(menu) == ["WKMenuItemIdentifierCut", "WKMenuItemIdentifierCopy", "WKMenuItemIdentifierPaste"])
    }

    /// POLISH right-click contract (Leo 2026-10-08): an image in the chat or its gallery offers
    /// Open Image (the page opens it as its click does) and WebKit's Copy Image, and no other
    /// WebKit image items.
    @Test func anImageOffersOpenAndCopyImage() throws {
        let menu = NSMenu()
        for id in ["WKMenuItemIdentifierOpenImageInNewWindow", "WKMenuItemIdentifierDownloadImage",
                   "WKMenuItemIdentifierCopyImage", "WKMenuItemIdentifierShareMenu"] {
            let item = NSMenuItem(title: id, action: nil, keyEquivalent: "")
            item.identifier = NSUserInterfaceItemIdentifier(id)
            menu.addItem(item)
        }
        var opened = 0
        let target = try #require(AgentPaneMessageTarget(report: ["openImage": true]))
        AgentPaneContextMenu.rebuild(menu, target: target, devTools: false,
                                     actions: .init(copy: { _ in }, fork: { _ in }, openImage: { opened += 1 }))
        #expect(Self.titles(menu) == [AgentPaneMenuStrings.openImage, "WKMenuItemIdentifierCopyImage"])
        Self.choose(try #require(menu.items.first))
        #expect(opened == 1)
    }

    @Test func choosingAnItemActsOnTheReportedMessage() throws {
        let (menu, copies, forks) = rebuilt(target: Self.reply, devTools: false)
        for title in [AgentPaneMenuStrings.copyMessage, AgentPaneMenuStrings.copyAsMarkdown, AgentPaneMenuStrings.forkFromHere] {
            Self.choose(try #require(menu.items.first { $0.title == title }))
        }
        #expect(copies() == ["Done. See the diff.", "**Done.** See the `diff`."])
        #expect(forks() == [7])
    }

    @Test func thePageReportReadsTextMarkdownAndForkPoint() {
        #expect(AgentPaneMessageTarget(report: ["text": "a", "markdown": "*a*", "forkSeq": NSNumber(value: 12)])
            == AgentPaneMessageTarget(text: "a", markdown: "*a*", forkSeq: 12))
        #expect(AgentPaneMessageTarget(report: NSNull()) == nil, "the pointer was not on a message")
        #expect(AgentPaneMessageTarget(report: ["text": ""]) == nil)
        #expect(AgentPaneMessageTarget(report: ["text": "a", "openImage": true]) == AgentPaneMessageTarget(text: "a", opensImage: true))
    }

    /// The pane end to end on both hosts: a page report, then the web view's menu hook WebKit runs
    /// when it opens the menu, then the person choosing items.
    @Test(arguments: [false, true])
    func thePaneUsesTheReportOnceAndCopiesToThePasteboard(pageHost: Bool) throws {
        let index = try #require(AgentPaneView.bundledPage)
        let view = try #require(AgentPaneView(model: AgentPaneModel(host: MockAgentPaneHost()), source: .bundled(index), pageHost: pageHost))
        defer { view.close() }
        var copied: [String] = []
        view.copyText = { copied.append($0) }
        var scripts: [String] = []
        view.evaluateScript = { scripts.append($0) }
        // What the web view's willOpenMenu runs on each host.
        let openMenu = try #require(pageHost ? view.page?.contextMenuEditor : (view.webView as? AgentPaneWKWebView)?.contextMenuEditor)

        view.receiveContextMenuReport(["text": "Done. See the diff.", "markdown": "**Done.**", "forkSeq": NSNumber(value: 7)])
        let menu = Self.webKitMenu()
        openMenu(menu)
        #expect(!Self.titles(menu).contains("WKMenuItemIdentifierReload"))
        Self.choose(try #require(menu.items.first { $0.title == AgentPaneMenuStrings.copyMessage }))
        #expect(copied == ["Done. See the diff."])
        Self.choose(try #require(menu.items.first { $0.title == AgentPaneMenuStrings.forkFromHere }))
        #expect(scripts.contains { $0.contains("chat.fork") && $0.contains("throughSeq: 7") })

        let next = Self.webKitMenu()
        openMenu(next)
        #expect(!Self.titles(next).contains(AgentPaneMenuStrings.copyMessage), "a report serves one menu")
    }
}
