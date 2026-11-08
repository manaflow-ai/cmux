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

    /// Choosing Copy Message on a reply copies its Markdown.
    @Test func aChosenPaneRowStillRuns() throws {
        var copied: [String] = []
        let menu = Self.menu(target: Self.reply, copied: { copied.append($0) })
        let item = try #require(menu.items.first { $0.title == AgentPaneMenuStrings.copyMessage })
        try Self.click(item)
        Self.drainRunLoop { !copied.isEmpty }
        #expect(copied == [Self.reply.markdown])
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
