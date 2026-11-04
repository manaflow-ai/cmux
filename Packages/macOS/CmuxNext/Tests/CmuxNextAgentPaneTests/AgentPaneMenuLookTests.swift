import AppKit
@testable import CmuxNextAgentPane
import CmuxNextDesign
import CmuxNextPages
import Testing

/// The agent chat's message menu is a standard macOS menu like every other right-click menu
/// (Lawrence 2026-10-23): each row is a plain AppKit row with an icon, and a chosen row still runs.
/// WebKit's own rows (Copy, Look Up...) run as the menu closes, while WebKit still holds the menu.
@Suite(.serialized)
@MainActor
struct AgentPaneMenuLookTests {
    /// WebKit's menu as the pane gets it: Copy (a WebKit item, with WebKit's target) and Reload.
    static func webKitMenu(_ webKit: MenuLookWebKitTarget) -> NSMenu {
        _ = NSApplication.shared
        let menu = NSMenu()
        for (identifier, title) in [("WKMenuItemIdentifierCopy", "Copy"), ("WKMenuItemIdentifierReload", "Reload")] {
            let item = NSMenuItem(title: title, action: #selector(MenuLookWebKitTarget.fire(_:)), keyEquivalent: "")
            item.identifier = NSUserInterfaceItemIdentifier(identifier)
            item.target = webKit
            menu.addItem(item)
        }
        return menu
    }

    static func menu(target: AgentPaneMessageTarget?, selection: String? = nil, webKit: MenuLookWebKitTarget = MenuLookWebKitTarget(),
                     copied: @escaping (String) -> Void = { _ in }, page: @escaping (String, [String: String]) -> Void = { _, _ in }) -> NSMenu {
        let menu = webKitMenu(webKit)
        AgentPaneContextMenu.rebuild(menu, target: target, selection: selection, devTools: false, scope: ThemeScope.app.fullStrength,
                                     actions: .init(copy: copied, fork: { _ in }, linkItems: { LinkMenu().linkItems(for: $0) }, page: page))
        return menu
    }

    static let prompt = AgentPaneMessageTarget(text: "Fix the build.", forkSeq: 2, sideChat: true, retryRowId: "row-1")
    static let docs = URL(string: "https://cmux.com/docs") ?? URL(fileURLWithPath: "/")
    static let reply = AgentPaneMessageTarget(text: "Done, see the docs.", markdown: "Done, see [the docs](https://cmux.com/docs).", forkSeq: 4,
                                              links: [docs], part: AgentPaneMenuPart(code: "make", link: docs))
    /// A reply with two links and no part under the pointer: Open Links ▸ with each link.
    static let links = AgentPaneMessageTarget(text: "Two links.", markdown: "Two [links](https://cmux.com/docs).",
                                              links: [docs, docs.appending(path: "blog")])

    @Test func aReplyMenuStartsWithItsQuietTimestamp() throws {
        let target = try #require(AgentPaneMessageTarget(report: [
            "text": "Done.", "markdown": "Done.", "replyTime": "Today, 5:29 PM",
        ]))
        let menu = Self.menu(target: target)
        let header = try #require(menu.items.first)
        #expect(header.title == "Today, 5:29 PM")
        #expect(header.action == nil)
        #expect(!header.isEnabled)
        #expect(header.image == nil)
        #expect(header.view == nil)
        #expect(menu.items[1].isSeparatorItem)
        #expect(menu.items.contains { $0.title == AgentPaneMenuStrings.copyMessage })
    }

    @Test func aPromptOrSelectionHasNoReplyTimestampHeader() {
        let prompt = AgentPaneMessageTarget(text: "Fix the build.", replyTime: "Today, 5:29 PM")
        #expect(Self.menu(target: prompt).items.first?.title != "Today, 5:29 PM")
        let reply = AgentPaneMessageTarget(text: "Done.", markdown: "Done.", replyTime: "Today, 5:29 PM")
        #expect(Self.menu(target: reply, selection: "Done").items.first?.title != "Today, 5:29 PM")
    }

    @Test(arguments: ["prompt", "reply", "links", "selection"])
    func everyRowIsNativeWithAnIcon(_ kind: String) throws {
        let menu = switch kind {
        case "prompt": Self.menu(target: Self.prompt)
        case "reply": Self.menu(target: Self.reply)
        case "links": Self.menu(target: Self.links)
        default: Self.menu(target: nil, selection: "the build")
        }
        let rows = Self.rows(of: menu)
        #expect(rows.count > 3, "\(kind): \(rows.map(\.title))")
        for item in rows {
            #expect(item.view == nil, "\(kind): \(item.title) is custom-drawn, not a standard macOS row")
            #expect(item.image != nil, "\(kind): \(item.title) has no icon")
        }
        // WebKit's Copy is kept and given the catalog's Copy symbol; its Reload is not kept.
        #expect(menu.items.contains { $0.identifier?.rawValue == "WKMenuItemIdentifierCopy" })
        #expect(!menu.items.contains { $0.identifier?.rawValue == "WKMenuItemIdentifierReload" })
    }

    /// Message copies preserve both the rendered text and the source Markdown.
    @Test func aChosenPaneRowStillRuns() throws {
        var copied: [String] = []
        let menu = Self.menu(target: Self.reply, copied: { copied.append($0) })
        let plain = try #require(menu.items.first { $0.title == AgentPaneMenuStrings.copyMessage })
        let markdown = try #require(menu.items.first { $0.title == AgentPaneMenuStrings.copyMessageAsMarkdown })
        try Self.click(plain)
        try Self.click(markdown)
        Self.drainRunLoop { !copied.isEmpty }
        #expect(copied == [Self.reply.text, Self.reply.markdown])
    }

    @Test func selectedMessageKeepsCopyRowsThenQuoteContextPinForkAndSearch() throws {
        var page: [(String, [String: String])] = []
        var quoted: [String] = []
        var attached: [String] = []
        let target = AgentPaneMessageTarget(text: "Rendered body", rowId: "summary-4", sessionId: "chat-1", markdown: "**Body**", forkSeq: 4)
        // Rebuild with the seam callbacks because the helper's defaults intentionally do nothing.
        let webKit = Self.webKitMenu(MenuLookWebKitTarget())
        AgentPaneContextMenu.rebuild(
            webKit,
            target: target,
            selection: "selected words",
            devTools: false,
            scope: ThemeScope.app.fullStrength,
            actions: .init(
                copy: { _ in },
                fork: { _ in },
                quoteReply: { quoted.append($0) },
                attachSelection: { attached.append($0) },
                search: { page.append(("search", ["text": $0])) },
                pinChapter: { rowId, sessionId in page.append(("pin", ["rowId": rowId, "sessionId": sessionId])) },
            ),
        )
        let titles = webKit.items.map { $0.isSeparatorItem ? "-" : $0.title }
        #expect(titles == [
            "Copy",
            AgentPaneMenuStrings.copyMessage,
            AgentPaneMenuStrings.copyMessageAsMarkdown,
            "-",
            AgentPaneMenuStrings.quoteInReply,
            AgentPaneMenuStrings.attachSelectionAsContext,
            "-",
            AgentPaneMenuStrings.pinAsChapter,
            AgentPaneMenuStrings.forkFromHere,
            AgentForkMenu.title,
            "-",
            AgentPaneMenuStrings.searchTheWeb,
            AgentPaneMenuStrings.askAboutThis,
        ])
        let quote = try #require(webKit.items.first { $0.title == AgentPaneMenuStrings.quoteInReply })
        let attach = try #require(webKit.items.first { $0.title == AgentPaneMenuStrings.attachSelectionAsContext })
        let pin = try #require(webKit.items.first { $0.title == AgentPaneMenuStrings.pinAsChapter })
        let search = try #require(webKit.items.first { $0.title == AgentPaneMenuStrings.searchTheWeb })
        try Self.click(quote)
        try Self.click(attach)
        try Self.click(pin)
        try Self.click(search)
        #expect(quoted == ["> selected words\n\n"])
        #expect(attached == ["selected words"])
        #expect(page.map { $0.0 } == ["pin", "search"])
        #expect(page.map { $0.1 } == [["rowId": "summary-4", "sessionId": "chat-1"], ["text": "selected words"]])
    }

    @Test func reportCarriesTheOwningSessionForStaleMenuGuards() throws {
        let target = try #require(
            AgentPaneMessageTarget(report: ["text": "Reply", "rowId": "summary-4", "sessionId": "chat-1"]),
        )
        #expect(target.rowId == "summary-4")
        #expect(target.sessionId == "chat-1")
    }

    /// Fork from Here's neighbour Open in Side Chat on a prompt runs the page's side chat action.
    @Test func aChosenPromptRowStillRuns() throws {
        var ran: [String] = []
        let menu = Self.menu(target: Self.prompt, page: { name, _ in ran.append(name) })
        let item = try #require(menu.items.first { $0.title == AgentPaneMenuStrings.openInSideChat })
        try Self.click(item)
        Self.drainRunLoop { !ran.isEmpty }
        #expect(ran == ["chat.side"])
    }

    /// Quote in Reply on selected text sends the quote to the composer's append path (the page's
    /// `chat.quoteReply`), never Edit and Resend's `chat.editPrompt`, which would replace the draft.
    @Test func quoteInReplyAppendsInsteadOfEditing() throws {
        var quoted: [String] = []
        var edited: [String] = []
        let menu = Self.webKitMenu(MenuLookWebKitTarget())
        AgentPaneContextMenu.rebuild(menu, target: nil, selection: "the build\nis green", devTools: false, scope: ThemeScope.app.fullStrength,
                                     actions: .init(copy: { _ in }, fork: { _ in }, edit: { edited.append($0) },
                                                    quoteReply: { quoted.append($0) }))
        let item = try #require(menu.items.first { $0.title == AgentPaneMenuStrings.quoteInReply })
        try Self.click(item)
        Self.drainRunLoop { !quoted.isEmpty || !edited.isEmpty }
        #expect(quoted == ["> the build\n> is green\n\n"])
        #expect(edited.isEmpty)
    }

    /// WebKit's Copy runs as the menu closes, not after: WebKit's target drops the menu once its
    /// popUp returns, so a run on a later turn of the run loop would copy nothing.
    @Test func webKitsOwnRowRunsBeforeTheMenuIsGone() throws {
        let webKit = MenuLookWebKitTarget()
        let menu = Self.menu(target: Self.prompt, webKit: webKit)
        let copy = try #require(menu.items.first { $0.identifier?.rawValue == "WKMenuItemIdentifierCopy" })
        try Self.click(copy)
        #expect(webKit.count == 1, "WebKit's Copy waited for the run loop")
        #expect(webKit.sender === copy, "WebKit reads its payload off its own item")
        Self.drainRunLoop { false }
        #expect(webKit.count == 1)
    }

    /// A right-click on a chat the transcript opens: Open on Right runs the click's open, and Go to
    /// Chat is there only when a tab already shows the chat (ask-e9c4803262).
    @Test func aChatPartOffersOpenOnRightAndGoToChat() throws {
        var opened: [String] = []
        var jumped = 0
        func menu(tabShown: Bool) -> NSMenu {
            let menu = Self.webKitMenu(MenuLookWebKitTarget())
            let jump: @MainActor () -> Void = { jumped += 1 }
            let goTo: (String, Bool) -> (@MainActor () -> Void)? = { _, _ in tabShown ? jump : nil }
            let open: (String, Bool) -> Void = { session, _ in opened.append(session) }
            var actions = AgentPaneContextMenu.Actions(copy: { _ in }, fork: { _ in })
            actions.openSession = open
            actions.goToSession = goTo
            let target = AgentPaneMessageTarget(text: "", part: AgentPaneMenuPart(session: "child"))
            AgentPaneContextMenu.rebuild(menu, target: target, devTools: false, scope: ThemeScope.app.fullStrength, actions: actions)
            return menu
        }
        #expect(!menu(tabShown: false).items.contains { $0.title == AgentPaneMenuStrings.goToChat })
        let shown = menu(tabShown: true)
        let goTo = try #require(shown.items.first { $0.title == AgentPaneMenuStrings.goToChat })
        try Self.click(goTo)
        Self.drainRunLoop { jumped > 0 }
        #expect(jumped == 1)
        // Kept: a row knows its menu only weakly, and choosing it goes through the menu.
        let again = menu(tabShown: true)
        let right = try #require(again.items.first { $0.title == AgentPaneMenuStrings.openOnRight })
        try Self.click(right)
        Self.drainRunLoop { !opened.isEmpty }
        #expect(opened == ["child"])
    }

    // MARK: Helpers

    private static func rows(of menu: NSMenu) -> [NSMenuItem] {
        menu.items.filter { !$0.isSeparatorItem }.flatMap { [$0] + ($0.submenu.map(rows(of:)) ?? []) }
    }

    /// Chooses the item, as AppKit does when its row is clicked.
    private static func click(_ item: NSMenuItem) throws {
        let menu = try #require(item.menu)
        menu.performActionForItem(at: menu.index(of: item))
    }

    /// Runs the main run loop in its default mode until `done` or a short deadline.
    private static func drainRunLoop(until done: () -> Bool) {
        let deadline = Date(timeIntervalSinceNow: 0.5)
        while !done(), Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.02))
        }
    }
}

/// WebKit's menu target stand-in: counts its runs and keeps the item it got.
final class MenuLookWebKitTarget: NSObject {
    private(set) var count = 0
    private(set) weak var sender: NSMenuItem?

    @objc func fire(_ sender: NSMenuItem) {
        count += 1
        self.sender = sender
    }
}
