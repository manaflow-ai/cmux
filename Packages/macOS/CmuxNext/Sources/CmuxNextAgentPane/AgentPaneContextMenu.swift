import AppKit

/// The message under the pointer when the agent pane's context menu opened, as the page reports it
/// on `contextmenu` (webviews conversation/messageMenu.ts), before WebKit asks the host for the menu.
struct AgentPaneMessageTarget: Equatable, Sendable {
    /// The message as a person reads it.
    var text: String
    /// An agent reply's Markdown source; nil for a prompt (it is plain text already).
    var markdown: String?
    /// The fork point of the message's turn (its summary's acpmux event); nil when acpmux does not
    /// serve forks or the turn has not ended.
    var forkSeq: Int?
    /// A prompt that was not sent: its row, for Retry.
    var retryRowId: String?
    /// The message's web links and images, for Open Link.
    var links: [URL]

    init(text: String, markdown: String? = nil, forkSeq: Int? = nil, retryRowId: String? = nil, links: [URL] = []) {
        self.text = text
        self.markdown = markdown
        self.forkSeq = forkSeq
        self.retryRowId = retryRowId
        self.links = links
    }

    /// A prompt (the person's own message) has no Markdown source.
    var isPrompt: Bool { markdown == nil }

    /// The page's report; nil for anything but a message with text (the pointer was elsewhere).
    init?(report body: Any?) {
        guard let object = body as? [String: Any], let text = object["text"] as? String, !text.isEmpty else { return nil }
        self.text = text
        markdown = (object["markdown"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        forkSeq = (object["forkSeq"] as? NSNumber).map(\.intValue)
        retryRowId = (object["retryRowId"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        links = (object["links"] as? [Any] ?? []).compactMap { ($0 as? String).flatMap(URL.init(string:)) }.filter(Self.isWebLink)
    }

    /// An http(s) link with a host and no credentials, the only kind the pane opens outside it.
    static func isWebLink(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return false }
        return url.user == nil && url.password == nil && url.host?.isEmpty == false
    }
}

/// The agent pane's native context menu. The pane is app chrome, so WebKit's default menu (Reload,
/// Back, Look Up, Share...) never shows: Cut, Copy and Paste where WebKit offers them (Copy on a
/// selection, Cut and Paste in the composer); for the message under the pointer Copy Message (a
/// reply's Markdown) and Copy as Plain Text, Retry on a prompt that was not sent, Edit and Resend
/// on a prompt, Fork from Here when its turn can be forked, and Open Link for its links and images;
/// the chat's menu (Change Background, zoom...) on empty space; and Inspect Element in builds with
/// developer tools.
@MainActor
enum AgentPaneContextMenu {
    /// WebKit's edit items the pane keeps, in WebKit's order.
    static let editItems: Set<String> = ["WKMenuItemIdentifierCut", "WKMenuItemIdentifierCopy", "WKMenuItemIdentifierPaste"]
    static let inspectItem = "WKMenuItemIdentifierInspectElement"

    struct Actions {
        var copy: (String) -> Void
        var fork: (Int) -> Void
        var retry: (String) -> Void = { _ in }
        var edit: (String) -> Void = { _ in }
        var open: (URL) -> Void = { _ in }
        var search: (String) -> Void = { _ in }
    }

    /// The selected transcript text the page reported with the menu (it reports a selection only
    /// when the pointer is inside it, never the composer's); nil without one.
    static func selection(report body: Any?) -> String? {
        nil
    }

    /// Replaces WebKit's items in `menu` with the pane's, in groups split by separators.
    static func rebuild(_ menu: NSMenu, target: AgentPaneMessageTarget?, selection: String? = nil, devTools: Bool,
                        chatMenu: [NSMenuItem] = [], actions: Actions) {
        let edits = menu.items.filter { editItems.contains($0.identifier?.rawValue ?? "") }
        let inspect = devTools ? menu.items.first { $0.identifier?.rawValue == inspectItem } : nil
        menu.removeAllItems()
        var copies = edits
        var message: [NSMenuItem] = []
        var links: [NSMenuItem] = []
        if let target {
            if let markdown = target.markdown {
                copies.append(AgentPaneMenuAction.item(AgentPaneMenuStrings.copyMessage) { actions.copy(markdown) })
                copies.append(AgentPaneMenuAction.item(AgentPaneMenuStrings.copyAsPlainText) { actions.copy(target.text) })
            } else {
                copies.append(AgentPaneMenuAction.item(AgentPaneMenuStrings.copyMessage) { actions.copy(target.text) })
            }
            if let row = target.retryRowId {
                message.append(AgentPaneMenuAction.item(AgentPaneMenuStrings.retry) { actions.retry(row) })
            }
            if target.isPrompt {
                message.append(AgentPaneMenuAction.item(AgentPaneMenuStrings.editAndResend) { actions.edit(target.text) })
            }
            if let seq = target.forkSeq {
                message.append(AgentPaneMenuAction.item(AgentPaneMenuStrings.forkFromHere) { actions.fork(seq) })
            }
            links = linkItems(target.links, open: actions.open)
        }
        // Empty space (no message, nothing to edit) gets the chat's own menu, its sections kept.
        let chat = target == nil && edits.isEmpty ? chatMenu.filter { $0.menu == nil } : []
        let groups: [[NSMenuItem]] = [copies, message, links, chat, inspect.map { [$0] } ?? []]
        for group in groups where !group.isEmpty {
            if menu.numberOfItems > 0 { menu.addItem(.separator()) }
            group.forEach(menu.addItem)
        }
    }

    /// Open Link for one link; Open Links with each link in a submenu for several.
    private static func linkItems(_ links: [URL], open: @escaping (URL) -> Void) -> [NSMenuItem] {
        guard let first = links.first else { return [] }
        if links.count == 1 { return [AgentPaneMenuAction.item(AgentPaneMenuStrings.openLink) { open(first) }] }
        let parent = NSMenuItem(title: AgentPaneMenuStrings.openLinks, action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: parent.title)
        for link in links {
            submenu.addItem(AgentPaneMenuAction.item(link.absoluteString) { open(link) })
        }
        parent.submenu = submenu
        return [parent]
    }
}

/// The context menu's item titles.
enum AgentPaneMenuStrings {
    static var copyMessage: String {
        String(localized: "agentPane.menu.copyMessage", defaultValue: "Copy Message", bundle: .module)
    }

    static var copyAsPlainText: String {
        String(localized: "agentPane.menu.copyAsPlainText", defaultValue: "Copy as Plain Text", bundle: .module)
    }

    static var retry: String {
        String(localized: "agentPane.menu.retry", defaultValue: "Retry", bundle: .module)
    }

    static var editAndResend: String {
        String(localized: "agentPane.menu.editAndResend", defaultValue: "Edit and Resend", bundle: .module)
    }

    static var openLink: String {
        String(localized: "agentPane.menu.openLink", defaultValue: "Open Link", bundle: .module)
    }

    static var openLinks: String {
        String(localized: "agentPane.menu.openLinks", defaultValue: "Open Links", bundle: .module)
    }

    static var quoteInReply: String {
        String(localized: "agentPane.menu.quoteInReply", defaultValue: "Quote in Reply", bundle: .module)
    }

    static var askAboutThis: String {
        String(localized: "agentPane.menu.askAboutThis", defaultValue: "Ask About This", bundle: .module)
    }

    /// What Ask About This writes under the quote, for the person to send or change.
    static var askAboutThisPrompt: String {
        String(localized: "agentPane.menu.askAboutThis.prompt", defaultValue: "Explain this.", bundle: .module)
    }

    static var searchTheWeb: String {
        String(localized: "agentPane.menu.searchTheWeb", defaultValue: "Search the Web", bundle: .module)
    }

    static var forkFromHere: String {
        String(localized: "agentPane.menu.forkFromHere", defaultValue: "Fork from Here", bundle: .module)
    }
}
