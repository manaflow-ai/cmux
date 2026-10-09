import AppKit
import Foundation
import Testing
import WebKit
@testable import CmuxNextAgentPane

/// The agent pane's context menu (cx-k9go; POLISH right-click contract): WebKit's default menu
/// (Reload, Look Up, Back...) never shows. Copy stays on a selection. On the message the page
/// reported under the pointer: Copy Message (a reply's Markdown) and Copy as Plain Text, Retry on a
/// prompt that was not sent, Edit and Resend on a prompt, Fork from Here on its turn, and Open Link
/// for its links and images. Inspect Element stays only in builds with developer tools.
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

    /// What the menu's items did, in order ("copy: text", "fork: 7", ...).
    final class Log {
        var done: [String] = []
    }

    private func rebuilt(target: AgentPaneMessageTarget?, devTools: Bool) -> (NSMenu, copies: () -> [String], forks: () -> [Int]) {
        let (menu, log) = rebuiltLogging(target: target, devTools: devTools)
        let values = { (kind: String) in log.done.filter { $0.hasPrefix("\(kind): ") }.map { String($0.dropFirst(kind.count + 2)) } }
        return (menu, { values("copy") }, { values("fork").compactMap { Int($0) } })
    }

    private func rebuiltLogging(target: AgentPaneMessageTarget?, devTools: Bool = false) -> (NSMenu, Log) {
        let menu = Self.webKitMenu()
        let log = Log()
        AgentPaneContextMenu.rebuild(menu, target: target, devTools: devTools, actions: .init(
            copy: { log.done.append("copy: \($0)") }, fork: { log.done.append("fork: \($0)") },
            retry: { log.done.append("retry: \($0)") }, edit: { log.done.append("edit: \($0)") },
            open: { log.done.append("open: \($0.absoluteString)") }))
        return (menu, log)
    }

    @Test func anAgentReplyOffersCopiesAndForkInMacOrder() {
        let (menu, _, _) = rebuilt(target: Self.reply, devTools: false)
        #expect(Self.titles(menu) == ["WKMenuItemIdentifierCopy", AgentPaneMenuStrings.copyMessage, AgentPaneMenuStrings.copyAsPlainText,
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

    @Test func aPromptOffersEditAndResendButNoPlainTextCopyOrFork() {
        let (menu, _, _) = rebuilt(target: AgentPaneMessageTarget(text: "fix the build"), devTools: false)
        #expect(Self.titles(menu) == ["WKMenuItemIdentifierCopy", AgentPaneMenuStrings.copyMessage, "-", AgentPaneMenuStrings.editAndResend])
    }

    @Test func aPromptThatWasNotSentOffersRetryFirst() throws {
        let (menu, log) = rebuiltLogging(target: AgentPaneMessageTarget(text: "deploy", retryRowId: "p9"))
        #expect(Self.titles(menu) == ["WKMenuItemIdentifierCopy", AgentPaneMenuStrings.copyMessage,
                                      "-", AgentPaneMenuStrings.retry, AgentPaneMenuStrings.editAndResend])
        Self.choose(try #require(menu.items.first { $0.title == AgentPaneMenuStrings.retry }))
        Self.choose(try #require(menu.items.first { $0.title == AgentPaneMenuStrings.editAndResend }))
        #expect(log.done == ["retry: p9", "edit: deploy"])
    }

    // MARK: Selected text

    private func rebuiltOnSelection(_ selection: String) -> (NSMenu, Log) {
        let menu = Self.webKitMenu()
        let log = Log()
        AgentPaneContextMenu.rebuild(menu, target: Self.reply, selection: selection, devTools: false, actions: .init(
            copy: { log.done.append("copy: \($0)") }, fork: { log.done.append("fork: \($0)") },
            edit: { log.done.append("edit: \($0)") }, search: { log.done.append("search: \($0)") }))
        return (menu, log)
    }

    /// The contract's selection menu: Copy, Quote in Reply, Ask About This, Search the Web and
    /// WebKit's Look Up (macOS adds Services last). The message's own rows stay out.
    @Test func selectedTextGetsTheSelectionMenu() {
        let (menu, _) = rebuiltOnSelection("Fixed")
        #expect(Self.titles(menu) == ["WKMenuItemIdentifierCopy", AgentPaneMenuStrings.quoteInReply, AgentPaneMenuStrings.askAboutThis,
                                      "-", AgentPaneMenuStrings.searchTheWeb, "WKMenuItemIdentifierLookUp"])
    }

    @Test func quoteAndAskPutTheSelectionInTheComposerAndSearchSearchesIt() throws {
        let (menu, log) = rebuiltOnSelection("line one\nline two")
        for title in [AgentPaneMenuStrings.quoteInReply, AgentPaneMenuStrings.askAboutThis, AgentPaneMenuStrings.searchTheWeb] {
            Self.choose(try #require(menu.items.first { $0.title == title }))
        }
        #expect(log.done == ["edit: > line one\n> line two\n\n",
                             "edit: > line one\n> line two\n\n\(AgentPaneMenuStrings.askAboutThisPrompt)",
                             "search: line one\nline two"])
    }

    @Test func thePageReportCarriesTheSelection() {
        #expect(AgentPaneContextMenu.selection(report: ["selection": "Fixed", "text": "Fixed it"]) == "Fixed")
        #expect(AgentPaneContextMenu.selection(report: ["selection": "  \n "]) == nil, "blank is no selection")
        #expect(AgentPaneContextMenu.selection(report: ["text": "Fixed it"]) == nil)
        #expect(AgentPaneContextMenu.selection(report: NSNull()) == nil)
    }

    @Test func aMessageWithOneLinkOpensIt() throws {
        let link = try #require(URL(string: "https://cmux.dev/docs"))
        let (menu, log) = rebuiltLogging(target: AgentPaneMessageTarget(text: "docs", markdown: "[docs](https://cmux.dev/docs)", links: [link]))
        #expect(Self.titles(menu).suffix(2) == ["-", AgentPaneMenuStrings.openLink])
        Self.choose(try #require(menu.items.first { $0.title == AgentPaneMenuStrings.openLink }))
        #expect(log.done == ["open: https://cmux.dev/docs"])
    }

    @Test func aMessageWithSeveralLinksListsThemUnderOpenLinks() throws {
        let links = try ["https://cmux.dev/docs", "https://cmux.dev/chart.png"].map { try #require(URL(string: $0)) }
        let (menu, log) = rebuiltLogging(target: AgentPaneMessageTarget(text: "see", markdown: "see", links: links))
        let parent = try #require(menu.items.last)
        #expect(parent.title == AgentPaneMenuStrings.openLinks)
        let submenu = try #require(parent.submenu)
        #expect(Self.titles(submenu) == ["https://cmux.dev/docs", "https://cmux.dev/chart.png"])
        Self.choose(submenu.items[1])
        #expect(log.done == ["open: https://cmux.dev/chart.png"])
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
        AgentPaneContextMenu.rebuild(menu, target: nil, devTools: false, actions: .init(copy: { _ in }, fork: { _ in }))
        #expect(Self.titles(menu) == ["WKMenuItemIdentifierCut", "WKMenuItemIdentifierCopy", "WKMenuItemIdentifierPaste"])
    }

    @Test func choosingAnItemActsOnTheReportedMessage() throws {
        let (menu, copies, forks) = rebuilt(target: Self.reply, devTools: false)
        for title in [AgentPaneMenuStrings.copyMessage, AgentPaneMenuStrings.forkFromHere] {
            Self.choose(try #require(menu.items.first { $0.title == title }))
        }
        #expect(copies() == ["**Done.** See the `diff`."], "Copy Message copies a reply's Markdown")
        Self.choose(try #require(menu.items.first { $0.title == AgentPaneMenuStrings.copyAsPlainText }))
        #expect(copies() == ["**Done.** See the `diff`.", "Done. See the diff."])
        #expect(forks() == [7])
    }

    @Test func thePageReportReadsTextMarkdownAndForkPoint() {
        #expect(AgentPaneMessageTarget(report: ["text": "a", "markdown": "*a*", "forkSeq": NSNumber(value: 12)])
            == AgentPaneMessageTarget(text: "a", markdown: "*a*", forkSeq: 12))
        #expect(AgentPaneMessageTarget(report: NSNull()) == nil, "the pointer was not on a message")
        #expect(AgentPaneMessageTarget(report: ["text": ""]) == nil)
    }

    @Test func thePageReportReadsRetryAndWebLinksOnly() {
        let target = AgentPaneMessageTarget(report: ["text": "deploy", "retryRowId": "p9",
                                                     "links": ["https://cmux.dev/a", "javascript:alert(1)", "file:///etc/hosts", 3]])
        #expect(target?.retryRowId == "p9")
        #expect(target?.links.map(\.absoluteString) == ["https://cmux.dev/a"])
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
        #expect(copied == ["**Done.**"])
        Self.choose(try #require(menu.items.first { $0.title == AgentPaneMenuStrings.forkFromHere }))
        #expect(scripts.contains { $0.contains("chat.fork") && $0.contains("throughSeq: 7") })

        let next = Self.webKitMenu()
        openMenu(next)
        #expect(!Self.titles(next).contains(AgentPaneMenuStrings.copyMessage), "a report serves one menu")
    }

    /// A right-click on empty space (WebKit offers no edit rows, no message under the pointer)
    /// shows the chat's own menu, never an empty menu that macOS fills with only Services.
    @Test func emptySpaceShowsTheChatMenu() {
        let menu = NSMenu()
        for id in ["WKMenuItemIdentifierReload", "WKMenuItemIdentifierGoBack"] {
            let item = NSMenuItem(title: id, action: nil, keyEquivalent: "")
            item.identifier = NSUserInterfaceItemIdentifier(id)
            menu.addItem(item)
        }
        let chat = [NSMenuItem(title: "Change Background…", action: nil, keyEquivalent: ""), .separator(),
                    NSMenuItem(title: "Find…", action: nil, keyEquivalent: "")]
        AgentPaneContextMenu.rebuild(menu, target: nil, devTools: false, chatMenu: chat,
                                     actions: .init(copy: { _ in }, fork: { _ in }))
        #expect(Self.titles(menu) == ["Change Background…", "-", "Find…"])
    }

    /// On a message or a selection the chat's menu stays out: those menus are about the text.
    @Test func aMessageOrSelectionKeepsTheChatMenuOut() {
        let chat = [NSMenuItem(title: "Change Background…", action: nil, keyEquivalent: "")]
        let onMessage = NSMenu()
        AgentPaneContextMenu.rebuild(onMessage, target: Self.reply, devTools: false, chatMenu: chat,
                                     actions: .init(copy: { _ in }, fork: { _ in }))
        #expect(!Self.titles(onMessage).contains("Change Background…"))
        let onSelection = Self.webKitMenu()
        AgentPaneContextMenu.rebuild(onSelection, target: nil, devTools: false, chatMenu: chat,
                                     actions: .init(copy: { _ in }, fork: { _ in }))
        #expect(Self.titles(onSelection) == ["WKMenuItemIdentifierCopy"])
    }
}
