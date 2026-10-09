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

    init(text: String, markdown: String? = nil, forkSeq: Int? = nil) {
        self.text = text
        self.markdown = markdown
        self.forkSeq = forkSeq
    }

    /// The page's report; nil for anything but a message with text (the pointer was elsewhere).
    init?(report body: Any?) {
        guard let object = body as? [String: Any], let text = object["text"] as? String, !text.isEmpty else { return nil }
        self.text = text
        markdown = (object["markdown"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        forkSeq = (object["forkSeq"] as? NSNumber).map(\.intValue)
    }
}

/// The agent pane's native context menu. The pane is app chrome, so WebKit's default menu (Reload,
/// Back, Look Up, Share...) never shows: Cut, Copy and Paste where WebKit offers them (Copy on a
/// selection, Cut and Paste in the composer), Copy Message and Copy as Markdown for the message
/// under the pointer, Fork from Here when its turn can be forked, and Inspect Element in builds
/// with developer tools.
@MainActor
enum AgentPaneContextMenu {
    /// WebKit's edit items the pane keeps, in WebKit's order.
    static let editItems: Set<String> = ["WKMenuItemIdentifierCut", "WKMenuItemIdentifierCopy", "WKMenuItemIdentifierPaste"]
    static let inspectItem = "WKMenuItemIdentifierInspectElement"

    struct Actions {
        var copy: (String) -> Void
        var fork: (Int) -> Void
    }

    /// Replaces WebKit's items in `menu` with the pane's, in groups split by separators.
    static func rebuild(_ menu: NSMenu, target: AgentPaneMessageTarget?, devTools: Bool, chatMenu: [NSMenuItem] = [],
                        actions: Actions) {
        let edits = menu.items.filter { editItems.contains($0.identifier?.rawValue ?? "") }
        let inspect = devTools ? menu.items.first { $0.identifier?.rawValue == inspectItem } : nil
        menu.removeAllItems()
        var copies = edits
        if let target {
            copies.append(AgentPaneMenuAction.item(AgentPaneMenuStrings.copyMessage) { actions.copy(target.text) })
            if let markdown = target.markdown {
                copies.append(AgentPaneMenuAction.item(AgentPaneMenuStrings.copyAsMarkdown) { actions.copy(markdown) })
            }
        }
        let fork: [NSMenuItem] = target?.forkSeq.map { seq in
            [AgentPaneMenuAction.item(AgentPaneMenuStrings.forkFromHere) { actions.fork(seq) }]
        } ?? []
        let groups: [[NSMenuItem]] = [copies, fork, inspect.map { [$0] } ?? []]
        for group in groups where !group.isEmpty {
            if menu.numberOfItems > 0 { menu.addItem(.separator()) }
            group.forEach(menu.addItem)
        }
    }
}

/// The context menu's item titles.
enum AgentPaneMenuStrings {
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
