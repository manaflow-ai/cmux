import AppKit
import CmuxNextDesign

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
    /// The message's web links and images, for Open Link.
    var links: [URL]
    /// The pointer is on an image the page opens on click.
    var opensImage: Bool
    /// The pointer is on an image (one the page opens, or one I sent): Copy Image, Save Image As…,
    /// Quick Look and Show in Finder act on it.
    var hasImage: Bool
    /// The code block, command, path or link under the pointer (webviews conversation/menuParts.ts).
    var part: AgentPaneMenuPart?

    init(text: String, markdown: String? = nil, forkSeq: Int? = nil, sideChat: Bool = false, retryRowId: String? = nil,
         links: [URL] = [], opensImage: Bool = false, hasImage: Bool? = nil, part: AgentPaneMenuPart? = nil) {
        self.text = text
        self.markdown = markdown
        self.forkSeq = forkSeq
        self.sideChat = sideChat
        self.retryRowId = retryRowId
        self.links = links
        self.opensImage = opensImage
        self.hasImage = hasImage ?? opensImage
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
        hasImage = opensImage || ((object["image"] as? NSNumber)?.boolValue ?? false)
        part = AgentPaneMenuPart(report: object["part"])
        guard !text.isEmpty || hasImage || part != nil else { return nil }
        self.text = text
        markdown = (object["markdown"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        forkSeq = (object["forkSeq"] as? NSNumber).map(\.intValue)
        sideChat = (object["sideChat"] as? NSNumber)?.boolValue ?? false
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
/// Back, Look Up, Share...) never shows: on an image Open Image, Copy Image, Save Image As…, Quick Look and Show in Finder; the items
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
    static let editItems: Set<String> = ["WKMenuItemIdentifierCut", "WKMenuItemIdentifierCopy", pasteItem]
    static let pasteItem = "WKMenuItemIdentifierPaste"
    /// WebKit's Look Up, kept on selected text: it shows the definition at the selection.
    static let lookUpItem = "WKMenuItemIdentifierLookUp"
    static let inspectItem = "WKMenuItemIdentifierInspectElement"
    static let copyImageItem = "WKMenuItemIdentifierCopyImage"

    struct Actions {
        var copy: (String) -> Void
        var fork: (Int) -> Void
        var retry: (String) -> Void = { _ in }
        var edit: (String) -> Void = { _ in }
        /// Quote in Reply: the Markdown quote goes after the composer's draft, which it keeps.
        var quoteReply: (String) -> Void = { _ in }
        var open: (URL) -> Void = { _ in }
        /// A link part's rows (``LinkMenu``): Open in cmux Browser, ..., Copy Link; nil: Open Link and Copy Link.
        var linkItems: ((URL) -> [NSMenuItem])? = nil
        /// A path part's rows after Open (``LinkMenu``); nil (or a nil answer): Copy Path.
        var pathItems: ((String) -> [NSMenuItem]?)? = nil
        var search: (String) -> Void = { _ in }
        /// One of the page's own menu actions (`window.cmuxAcpmuxActions`) by name.
        var page: (String, [String: String]) -> Void = { _, _ in }
        /// The web view WebKit's Paste item runs `paste:` on (``AgentPaneDroppedPaths``); nil keeps WebKit's own action.
        var pasteTarget: AnyObject?
        /// The Labs pointer inspector, offered for every app-owned webview element.
        var inspectElement: (() -> Void)? = nil
    }

    /// The selected transcript text the page reported with the menu (it reports a selection only
    /// when the pointer is inside it, never the composer's); nil without one.
    static func selection(report body: Any?) -> String? {
        guard let text = (body as? [String: Any])?["selection"] as? String,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }

    /// The More button the page reported the message from (`popUp`, CSS px in the page's viewport):
    /// the pane opens the message's menu under it. Nil for a right-click's report.
    static func popUpAnchor(report body: Any?) -> CGRect? {
        guard let box = (body as? [String: Any])?["popUp"] as? [String: Any] else { return nil }
        let edge = { (key: String) in (box[key] as? NSNumber)?.doubleValue }
        guard let left = edge("left"), let top = edge("top"), let right = edge("right"), let bottom = edge("bottom") else { return nil }
        return CGRect(x: left, y: top, width: max(0, right - left), height: max(0, bottom - top))
    }

    /// The top-leading corner, in screen points (y up), of a menu of `size` opened from the More
    /// button at `button`, 2 pt from it: under the button when the whole menu fits there in the
    /// window's visible part, else above it when it fits there. With room on neither side of the
    /// window, the side where it fits on the screen (below first), else the screen's roomier side:
    /// picked by the window's room, a short window near the screen's top sent it up past the window
    /// and the screen's edge pushed it back down over its button. Past the window on that side it
    /// still stays on the screen, where AppKit would shrink it to a
    /// scroll arrow (Lucas, 2026-11-02: the last reply's menu, just over the composer, hid Open in
    /// Side Chat and the rows after it). Not ``PopupAnchor``: in a window too short for either side
    /// that slides the menu over the button.
    /// - Parameters:
    ///   - button: The button's rect on screen.
    ///   - size: The menu's size (`NSMenu.size`).
    ///   - visible: The screen's visible frame; nil with no screen.
    ///   - window: The window's content rect on screen; nil with no window.
    static func popUpOrigin(button: CGRect, size: CGSize, visible: CGRect?, window: CGRect?) -> CGPoint {
        let gap: CGFloat = 2
        let shown = window.map { visible?.intersection($0) ?? $0 }
        guard let area = shown.flatMap({ $0.isNull ? nil : $0 }) ?? visible else {
            return CGPoint(x: button.minX, y: button.minY - gap)
        }
        let below = button.minY - gap - area.minY, above = area.maxY - button.maxY - gap
        let opensUp: Bool
        if size.height <= below {
            opensUp = false
        } else if size.height <= above {
            opensUp = true
        } else if let visible {
            let screenBelow = button.minY - gap - visible.minY, screenAbove = visible.maxY - button.maxY - gap
            opensUp = size.height > screenBelow && (size.height <= screenAbove || screenAbove > screenBelow)
        } else {
            opensUp = above > below
        }
        var top = opensUp ? button.maxY + gap + size.height : button.minY - gap
        if let visible { top = min(max(top, visible.minY + size.height), visible.maxY) }
        return CGPoint(x: button.minX, y: top)
    }

    /// `text` as a Markdown quote, with a blank line after it for the reply.
    static func quote(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false).map { "> \($0)" }.joined(separator: "\n") + "\n\n"
    }

    /// The symbols of WebKit's items the pane keeps: the catalog's Copy, Paste, Copy Image, Look Up
    /// and Inspect Element symbols (Terminal, BrowserHit and Browser catalogs).
    static let webKitSymbols: [String: String] = [
        "WKMenuItemIdentifierCut": "scissors", "WKMenuItemIdentifierCopy": "doc.on.doc", "WKMenuItemIdentifierPaste": "doc.on.clipboard",
        copyImageItem: "doc.on.doc", lookUpItem: "character.book.closed", inspectItem: "cursorarrow.rays",
    ]

    /// A row's SF Symbol as a template image, as the action registry's menus draw theirs.
    static func icon(_ symbol: String) -> NSImage? {
        NSImage.menuSymbol(symbol)
    }

    /// WebKit's own item (Cut, Copy, Look Up...): its target forgets the menu once WebKit's popUp
    /// returns, so it must run as the menu closes, as a native row does.
    static func isWebKitItem(_ item: NSMenuItem) -> Bool {
        item.identifier?.rawValue.hasPrefix("WKMenuItemIdentifier") == true
    }

    /// Replaces WebKit's items in `menu` with the pane's, in groups split by separators. With a
    /// `scope` (the pane's), the menu opens in its light or dark look (`NSMenu.themeRows(in:)`): a
    /// standard macOS menu, each row with its icon.
    static func rebuild(_ menu: NSMenu, target: AgentPaneMessageTarget?, selection: String? = nil, devTools: Bool,
                        chatMenu: [NSMenuItem] = [], scope: ThemeScope? = nil, actions: Actions) {
        fill(menu, target: target, selection: selection, devTools: devTools, chatMenu: chatMenu, actions: actions)
        if let scope { menu.themeRows(in: scope) { isWebKitItem($0) } }
    }

    private static func fill(_ menu: NSMenu, target: AgentPaneMessageTarget?, selection: String?, devTools: Bool,
                             chatMenu: [NSMenuItem], actions: Actions) {
        let edits = menu.items.filter { editItems.contains($0.identifier?.rawValue ?? "") }
        // WebKit's Paste item pastes in the web process, past the view's `paste:`: it goes through the
        // view instead, which records the pasteboard's files first, as Cmd-V does. It keeps the
        // enabled state WebKit gave it (or the view validates it, as it does Edit > Paste).
        if let target = actions.pasteTarget, let paste = edits.first(where: { $0.identifier?.rawValue == pasteItem }) {
            paste.target = target
            paste.action = #selector(NSText.paste(_:))
        }
        // The UI pointer item owns this app surface while enabled. Do not leave WebKit's
        // browser inspector beside it with the same title.
        let inspect = devTools && actions.inspectElement == nil ? menu.items.first { $0.identifier?.rawValue == inspectItem } : nil
        let inspectElement = actions.inspectElement.map {
            AgentPaneMenuAction.item("Inspect Element", symbol: "scope", handler: $0)
        }
        let lookUp = menu.items.first { $0.identifier?.rawValue == lookUpItem }
        let copyImage = menu.items.first { $0.identifier?.rawValue == copyImageItem }
        for item in edits + [inspect, lookUp, copyImage].compactMap({ $0 }) where item.image == nil {
            item.image = webKitSymbols[item.identifier?.rawValue ?? ""].flatMap(icon)
        }
        menu.removeAllItems()
        if let selection {
            // Selected text gets the selection menu alone (macOS adds Services last).
            let quote = Self.quote(selection)
            let selected = edits + [
                AgentPaneMenuAction.item(AgentPaneMenuStrings.quoteInReply, symbol: "text.quote") { actions.quoteReply(quote) },
                AgentPaneMenuAction.item(AgentPaneMenuStrings.askAboutThis, symbol: "questionmark.bubble") { actions.edit(quote + AgentPaneMenuStrings.askAboutThisPrompt) },
            ]
            let find = [AgentPaneMenuAction.item(AgentPaneMenuStrings.searchTheWeb, symbol: "magnifyingglass") { actions.search(selection) }] + (lookUp.map { [$0] } ?? [])
            add([selected, find, inspectElement.map { [$0] } ?? inspect.map { [$0] } ?? []], to: menu)
            return
        }
        var image: [NSMenuItem] = []
        if target?.opensImage == true {
            image.append(AgentPaneMenuAction.item(AgentPaneMenuStrings.openImage, symbol: "photo.on.rectangle") { actions.page("chat.menu.openImage", [:]) })
        }
        if target?.hasImage == true {
            // The page sends the image to the host, which acts on a named copy (AgentPaneImageCopies+Menu):
            // Copy Image puts the file and its bytes on the pasteboard, on Chromium and WebKit alike.
            image.append(AgentPaneMenuAction.item(AgentPaneMenuStrings.copyImage, symbol: "doc.on.doc") { actions.page("chat.menu.copyImage", [:]) })
            image.append(AgentPaneMenuAction.item(AgentPaneMenuStrings.saveImageAs, symbol: "square.and.arrow.down") { actions.page("chat.menu.saveImage", [:]) })
            image.append(AgentPaneMenuAction.item(AgentPaneMenuStrings.quickLook, symbol: "eye") { actions.page("chat.menu.quickLookImage", [:]) })
            image.append(AgentPaneMenuAction.item(AgentPaneMenuStrings.showInFinder, symbol: "macwindow") { actions.page("chat.menu.revealImage", [:]) })
        } else if let copyImage {
            image.append(copyImage)
        }
        let part = target?.part?.items(copy: actions.copy, openPath: { actions.page("chat.menu.openPath", ["path": $0]) }, open: actions.open,
                                       linkItems: actions.linkItems, pathItems: actions.pathItems) ?? []
        var copies = edits
        var message: [NSMenuItem] = []
        var links: [NSMenuItem] = []
        if let target, !target.text.isEmpty {
            if let markdown = target.markdown {
                copies.append(AgentPaneMenuAction.item(AgentPaneMenuStrings.copyMessage, symbol: "doc.on.doc") { actions.copy(markdown) })
                copies.append(AgentPaneMenuAction.item(AgentPaneMenuStrings.copyAsPlainText, symbol: "doc.plaintext") { actions.copy(target.text) })
            } else {
                copies.append(AgentPaneMenuAction.item(AgentPaneMenuStrings.copyMessage, symbol: "doc.on.doc") { actions.copy(target.text) })
            }
            // Quote in Reply without selecting first (u18673): the whole message, as the reader sees it in Markdown,
            // appended to the draft like the selection's Quote in Reply, never Edit and Resend's replace.
            let quoted = Self.quote(target.markdown ?? target.text)
            message.append(AgentPaneMenuAction.item(AgentPaneMenuStrings.quoteInReply, symbol: "text.quote") { actions.quoteReply(quoted) })
            if let row = target.retryRowId {
                message.append(AgentPaneMenuAction.item(AgentPaneMenuStrings.retry, symbol: "arrow.clockwise") { actions.retry(row) })
            }
            if target.isPrompt {
                message.append(AgentPaneMenuAction.item(AgentPaneMenuStrings.editAndResend, symbol: "pencil") { actions.edit(target.text) })
            }
            if let seq = target.forkSeq {
                message.append(AgentPaneMenuAction.item(AgentPaneMenuStrings.forkFromHere, symbol: "arrow.triangle.branch") { actions.fork(seq) })
                // The chat menu's New side chat, through this turn (the page's `chat.side`).
                if target.sideChat {
                    message.append(AgentPaneMenuAction.item(AgentPaneMenuStrings.openInSideChat, symbol: "sidebar.right") {
                        actions.page("chat.side", ["throughSeq": String(seq)])
                    })
                }
            }
            if let seq = target.forkSeq {
                message.append(AgentForkMenu.item { destination in
                    actions.page("chat.fork", ["throughSeq": String(seq), "placement": destination.rawValue])
                })
            }
            // On a link, the part's Open Link stands for the message's.
            links = target.part?.link == nil ? linkItems(target.links, open: actions.open) : []
        }
        // Empty space (no message, no image, nothing to edit) gets the chat's own menu, its sections kept.
        let chat = target == nil && edits.isEmpty && image.isEmpty ? chatMenu.filter { $0.menu == nil } : []
        add([image, part, copies, message, links, chat, inspectElement.map { [$0] } ?? inspect.map { [$0] } ?? []], to: menu)
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
        if links.count == 1 { return [AgentPaneMenuAction.item(AgentPaneMenuStrings.openLink, symbol: "arrow.up.right.square") { open(first) }] }
        let parent = NSMenuItem(title: AgentPaneMenuStrings.openLinks, action: nil, keyEquivalent: "")
        parent.image = icon("arrow.up.right.square")
        let submenu = NSMenu(title: parent.title)
        for link in links {
            let item = AgentPaneMenuAction.item(linkTitle(link), symbol: "link") { open(link) }
            item.toolTip = link.absoluteString // tooltip-native-allow: NSMenuItem (AgentPaneMenuAction.item)
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

    static var copyFile: String {
        String(localized: "agentPane.menu.copyFile", defaultValue: "Copy", bundle: .module)
    }

    static var saveAs: String {
        String(localized: "agentPane.menu.saveAs", defaultValue: "Save As…", bundle: .module)
    }

    static var copyImage: String {
        String(localized: "agentPane.menu.copyImage", defaultValue: "Copy Image", bundle: .module)
    }

    static var saveImageAs: String {
        String(localized: "agentPane.menu.saveImageAs", defaultValue: "Save Image As…", bundle: .module)
    }

    static var quickLook: String {
        String(localized: "agentPane.menu.quickLook", defaultValue: "Quick Look", bundle: .module)
    }

    static var showInFinder: String {
        String(localized: "agentPane.menu.showInFinder", defaultValue: "Show in Finder", bundle: .module)
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
