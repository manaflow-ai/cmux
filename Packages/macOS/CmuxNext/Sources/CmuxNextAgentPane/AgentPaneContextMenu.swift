import AppKit

/// The message and image under the pointer when the agent pane's context menu opened, as the page
/// reports them on `contextmenu` (webviews conversation/messageMenu.ts), before WebKit asks the host
/// for the menu.
struct AgentPaneMessageTarget: Equatable, Sendable {
    /// The message as a person reads it; empty for an image outside a message (the gallery).
    var text: String
    /// An agent reply's Markdown source; nil for a prompt (it is plain text already).
    var markdown: String?
    /// The fork point of the message's turn (its summary's acpmux event); nil when acpmux does not
    /// serve forks or the turn has not ended.
    var forkSeq: Int?
    /// The chat opens a side chat (a fork in a split beside it) through ``forkSeq``.
    var sideChat: Bool
    /// A prompt that was not sent: its row, for Retry.
    var retryRowId: String?
    /// A prompt's row, for Edit and Resend: the page edits it in its bubble where the chat can fork before it.
    var promptRowId: String?
    /// The message's web links and images, for Open Link.
    var links: [URL]
    /// The pointer is on an image the page opens on click.
    var opensImage: Bool
    /// The code block, command, path or link under the pointer (webviews conversation/menuParts.ts).
    var part: AgentPaneMenuPart?

    init(text: String, markdown: String? = nil, forkSeq: Int? = nil, sideChat: Bool = false, retryRowId: String? = nil,
         promptRowId: String? = nil, links: [URL] = [], opensImage: Bool = false, part: AgentPaneMenuPart? = nil) {
        self.text = text
        self.markdown = markdown
        self.forkSeq = forkSeq
        self.sideChat = sideChat
        self.retryRowId = retryRowId
        self.promptRowId = promptRowId
        self.links = links
        self.opensImage = opensImage
        self.part = part
    }

    /// A prompt (the person's own message) has no Markdown source.
    var isPrompt: Bool { markdown == nil }

    /// The page's report; nil for anything but a message with text, an image or a part (the
    /// pointer was elsewhere).
    init?(report body: Any?) {
        guard let object = body as? [String: Any] else { return nil }
        let text = object["text"] as? String ?? ""
        opensImage = (object["openImage"] as? NSNumber)?.boolValue ?? false
        part = AgentPaneMenuPart(report: object["part"])
        guard !text.isEmpty || opensImage || part != nil else { return nil }
        self.text = text
        markdown = (object["markdown"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        forkSeq = (object["forkSeq"] as? NSNumber).map(\.intValue)
        sideChat = (object["sideChat"] as? NSNumber)?.boolValue ?? false
        retryRowId = (object["retryRowId"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        promptRowId = (object["promptRowId"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        links = (object["links"] as? [Any] ?? []).compactMap { ($0 as? String).flatMap(URL.init(string:)) }.filter(Self.isWebLink)
    }

    /// An http(s) link with a host and no credentials, the only kind the pane opens outside it.
    static func isWebLink(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return false }
        return url.user == nil && url.password == nil && url.host?.isEmpty == false
    }
}

/// The agent pane's native context menu. The pane is app chrome, so WebKit's default menu (Reload,
/// Back, Look Up, Share...) never shows: Open Image and WebKit's Copy Image on an image; the items
/// of the code block, command, path or link under the pointer (``AgentPaneMenuPart``, cx-2lm4);
/// Cut, Copy and Paste where WebKit offers them (Copy on a
/// selection, Cut and Paste in the composer); for the message under the pointer Copy Message (a
/// reply's Markdown) and Copy as Plain Text, Retry on a prompt that was not sent, Edit and Resend
/// on a prompt, Fork from Here when its turn can be forked, and Open Link for its links and images;
/// the chat's menu (Change Background, zoom...) on empty space; on selected text Copy, Quote in
/// Reply, Ask About This, Search the Web and Look Up; and Inspect Element in builds with developer
/// tools.
@MainActor
enum AgentPaneContextMenu {
    /// WebKit's edit items the pane keeps, in WebKit's order.
    static let editItems: Set<String> = ["WKMenuItemIdentifierCut", "WKMenuItemIdentifierCopy", "WKMenuItemIdentifierPaste"]
    /// WebKit's Look Up, kept on selected text: it shows the definition at the selection.
    static let lookUpItem = "WKMenuItemIdentifierLookUp"
    static let inspectItem = "WKMenuItemIdentifierInspectElement"
    static let copyImageItem = "WKMenuItemIdentifierCopyImage"

    struct Actions {
        var copy: (String) -> Void
        var fork: (Int) -> Void
        var retry: (String) -> Void = { _ in }
        var edit: (String) -> Void = { _ in }
        /// Edit and Resend on a prompt: its text and row (the page edits it in place where it can).
        var editPrompt: ((String, String?) -> Void)? = nil
        var open: (URL) -> Void = { _ in }
        /// A link part's rows (``LinkMenu``): Open in cmux Browser, ..., Copy Link; nil: Open Link and Copy Link.
        var linkItems: ((URL) -> [NSMenuItem])? = nil
        /// A path part's rows after Open (``LinkMenu``); nil (or a nil answer): Copy Path.
        var pathItems: ((String) -> [NSMenuItem]?)? = nil
        var search: (String) -> Void = { _ in }
        /// One of the page's own menu actions (`window.cmuxAcpmuxActions`) by name.
        var page: (String, [String: String]) -> Void = { _, _ in }
    }

    /// The selected transcript text the page reported with the menu (it reports a selection only
    /// when the pointer is inside it, never the composer's); nil without one.
    static func selection(report body: Any?) -> String? {
        guard let text = (body as? [String: Any])?["selection"] as? String,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }

    /// `text` as a Markdown quote, with a blank line after it for the reply.
    static func quote(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false).map { "> \($0)" }.joined(separator: "\n") + "\n\n"
    }

    /// Replaces WebKit's items in `menu` with the pane's, in groups split by separators.
    static func rebuild(_ menu: NSMenu, target: AgentPaneMessageTarget?, selection: String? = nil, devTools: Bool,
                        chatMenu: [NSMenuItem] = [], actions: Actions) {
        let edits = menu.items.filter { editItems.contains($0.identifier?.rawValue ?? "") }
        let inspect = devTools ? menu.items.first { $0.identifier?.rawValue == inspectItem } : nil
        let lookUp = menu.items.first { $0.identifier?.rawValue == lookUpItem }
        let copyImage = menu.items.first { $0.identifier?.rawValue == copyImageItem }
        menu.removeAllItems()
        if let selection {
            // Selected text gets the selection menu alone (macOS adds Services last).
            let quote = Self.quote(selection)
            let selected = edits + [
                AgentPaneMenuAction.item(AgentPaneMenuStrings.quoteInReply) { actions.edit(quote) },
                AgentPaneMenuAction.item(AgentPaneMenuStrings.askAboutThis) { actions.edit(quote + AgentPaneMenuStrings.askAboutThisPrompt) },
            ]
            let find = [AgentPaneMenuAction.item(AgentPaneMenuStrings.searchTheWeb) { actions.search(selection) }] + (lookUp.map { [$0] } ?? [])
            add([selected, find, inspect.map { [$0] } ?? []], to: menu)
            return
        }
        var image: [NSMenuItem] = []
        if target?.opensImage == true {
            image.append(AgentPaneMenuAction.item(AgentPaneMenuStrings.openImage) { actions.page("chat.menu.openImage", [:]) })
        }
        if let copyImage { image.append(copyImage) }
        let part = target?.part?.items(copy: actions.copy, openPath: { actions.page("chat.menu.openPath", ["path": $0]) }, open: actions.open,
                                       linkItems: actions.linkItems, pathItems: actions.pathItems) ?? []
        var copies = edits
        var message: [NSMenuItem] = []
        var links: [NSMenuItem] = []
        if let target, !target.text.isEmpty {
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
                message.append(AgentPaneMenuAction.item(AgentPaneMenuStrings.editAndResend) {
                    if let editPrompt = actions.editPrompt { editPrompt(target.text, target.promptRowId) } else { actions.edit(target.text) }
                })
            }
            if let seq = target.forkSeq {
                message.append(AgentPaneMenuAction.item(AgentPaneMenuStrings.forkFromHere) { actions.fork(seq) })
                // The chat menu's New side chat, through this turn (the page's `chat.side`).
                if target.sideChat {
                    message.append(AgentPaneMenuAction.item(AgentPaneMenuStrings.openInSideChat) {
                        actions.page("chat.side", ["throughSeq": String(seq)])
                    })
                }
            }
            // On a link, the part's Open Link stands for the message's.
            links = target.part?.link == nil ? linkItems(target.links, open: actions.open) : []
        }
        // Empty space (no message, no image, nothing to edit) gets the chat's own menu, its sections kept.
        let chat = target == nil && edits.isEmpty && image.isEmpty ? chatMenu.filter { $0.menu == nil } : []
        add([image, part, copies, message, links, chat, inspect.map { [$0] } ?? []], to: menu)
    }

    /// Adds the non-empty groups, split by separators.
    private static func add(_ groups: [[NSMenuItem]], to menu: NSMenu) {
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
            let item = AgentPaneMenuAction.item(linkTitle(link)) { open(link) }
            item.toolTip = link.absoluteString
            submenu.addItem(item)
        }
        parent.submenu = submenu
        return [parent]
    }

    /// A link as its address without `http(s)://` (port, query and fragment kept, so two links stay
    /// apart), cut in the middle past 60 characters; the full address is the item's tooltip.
    static func linkTitle(_ link: URL) -> String {
        let limit = 60
        let address = link.absoluteString
        let web = link.scheme == "http" || link.scheme == "https"
        let bare = web ? String(address.drop(while: { $0 != ":" }).dropFirst(3)) : address
        guard bare.count > limit else { return bare }
        let tail = limit / 3
        return String(bare.prefix(limit - tail - 1)) + "…" + String(bare.suffix(tail))
    }
}

/// The context menu's item titles.
enum AgentPaneMenuStrings {
    static var openImage: String {
        String(localized: "agentPane.menu.openImage", defaultValue: "Open Image", bundle: .module)
    }

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

    static var copyLink: String {
        String(localized: "agentPane.menu.copyLink", defaultValue: "Copy Link", bundle: .module)
    }

    static var copyCode: String {
        String(localized: "agentPane.menu.copyCode", defaultValue: "Copy Code", bundle: .module)
    }

    static var copyCommand: String {
        String(localized: "agentPane.menu.copyCommand", defaultValue: "Copy Command", bundle: .module)
    }

    static var copyOutput: String {
        String(localized: "agentPane.menu.copyOutput", defaultValue: "Copy Output", bundle: .module)
    }

    static var open: String {
        String(localized: "agentPane.menu.open", defaultValue: "Open", bundle: .module)
    }

    static var copyPath: String {
        String(localized: "agentPane.menu.copyPath", defaultValue: "Copy Path", bundle: .module)
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

    static var openInSideChat: String {
        String(localized: "agentPane.menu.openInSideChat", defaultValue: "Open in Side Chat", bundle: .module)
    }
}
