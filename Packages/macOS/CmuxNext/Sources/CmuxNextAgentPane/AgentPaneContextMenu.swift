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
    /// The pointer is on an image the page opens on click.
    var opensImage: Bool

    init(text: String, markdown: String? = nil, forkSeq: Int? = nil, opensImage: Bool = false) {
        self.text = text
        self.markdown = markdown
        self.forkSeq = forkSeq
        self.opensImage = opensImage
    }

    /// The page's report; nil for anything but a message with text or an image (the pointer was
    /// elsewhere).
    init?(report body: Any?) {
        guard let object = body as? [String: Any] else { return nil }
        let text = object["text"] as? String ?? ""
        opensImage = (object["openImage"] as? NSNumber)?.boolValue ?? false
        guard !text.isEmpty || opensImage else { return nil }
        self.text = text
        markdown = (object["markdown"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        forkSeq = (object["forkSeq"] as? NSNumber).map(\.intValue)
    }
}

/// The agent pane's native context menu. The pane is app chrome, so WebKit's default menu (Reload,
/// Back, Look Up, Share...) never shows: Open Image and WebKit's Copy Image on an image, Cut, Copy
/// and Paste where WebKit offers them (Copy on a selection, Cut and Paste in the composer), Copy
/// Message and Copy as Markdown for the message under the pointer, Fork from Here when its turn can
/// be forked, and Inspect Element in builds with developer tools.
@MainActor
enum AgentPaneContextMenu {
    /// WebKit's edit items the pane keeps, in WebKit's order.
    static let editItems: Set<String> = ["WKMenuItemIdentifierCut", "WKMenuItemIdentifierCopy", "WKMenuItemIdentifierPaste"]
    static let inspectItem = "WKMenuItemIdentifierInspectElement"
    static let copyImageItem = "WKMenuItemIdentifierCopyImage"

    struct Actions {
        var copy: (String) -> Void
        var fork: (Int) -> Void
        var openImage: () -> Void
    }

    /// Replaces WebKit's items in `menu` with the pane's, in groups split by separators.
    static func rebuild(_ menu: NSMenu, target: AgentPaneMessageTarget?, devTools: Bool, actions: Actions) {
        let edits = menu.items.filter { editItems.contains($0.identifier?.rawValue ?? "") }
        let inspect = devTools ? menu.items.first { $0.identifier?.rawValue == inspectItem } : nil
        let copyImage = menu.items.first { $0.identifier?.rawValue == copyImageItem }
        menu.removeAllItems()
        var image: [NSMenuItem] = []
        if target?.opensImage == true {
            image.append(AgentPaneMenuAction.item(AgentPaneMenuStrings.openImage) { actions.openImage() })
        }
        if let copyImage { image.append(copyImage) }
        var copies = edits
        if let target, !target.text.isEmpty {
            copies.append(AgentPaneMenuAction.item(AgentPaneMenuStrings.copyMessage) { actions.copy(target.text) })
            if let markdown = target.markdown {
                copies.append(AgentPaneMenuAction.item(AgentPaneMenuStrings.copyAsMarkdown) { actions.copy(markdown) })
            }
        }
        let fork: [NSMenuItem] = target?.forkSeq.map { seq in
            [AgentPaneMenuAction.item(AgentPaneMenuStrings.forkFromHere) { actions.fork(seq) }]
        } ?? []
        let groups: [[NSMenuItem]] = [image, copies, fork, inspect.map { [$0] } ?? []]
        for group in groups where !group.isEmpty {
            if menu.numberOfItems > 0 { menu.addItem(.separator()) }
            group.forEach(menu.addItem)
        }
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

    static var copyAsMarkdown: String {
        String(localized: "agentPane.menu.copyAsMarkdown", defaultValue: "Copy as Markdown", bundle: .module)
    }

    static var forkFromHere: String {
        String(localized: "agentPane.menu.forkFromHere", defaultValue: "Fork from Here", bundle: .module)
    }
}
