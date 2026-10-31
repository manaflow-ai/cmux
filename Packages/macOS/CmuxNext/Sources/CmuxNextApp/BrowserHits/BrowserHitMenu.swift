import AppKit
import CmuxNextActions
import CmuxNextBrowser

/// The rows a page right-click shows for its link, image and selection,
/// the same in WebKit and Chromium (R123): generated from the
/// `browserLink`, `browserImage` and `browserSelection` placements with the
/// hit's `url` and `text`, so each row runs its catalog action through the
/// registry, like the palette and the CLI. Chromium shows them before its
/// remaining rows; WebKit puts them at the top of its own menu.
enum BrowserHitMenu {
    /// One generated menu: its placements' context, the arguments every row
    /// runs with, and the rows the hit cannot fill.
    struct Section: Equatable {
        let context: ActionMenuContext
        let arguments: [String: ActionValue]
        let hidden: Set<ActionID>
    }

    /// Pure: the sections for `target`, in order link, image, selection.
    /// A link without known text has no Copy Link Text; a selection inside
    /// an editable field keeps the engine's edit rows instead.
    static func sections(for target: BrowserContextMenuTarget) -> [Section] {
        var sections: [Section] = []
        if let link = target.linkURL {
            let text = target.linkText.trimmingCharacters(in: .whitespacesAndNewlines)
            var arguments: [String: ActionValue] = ["url": .string(link.absoluteString)]
            if !text.isEmpty { arguments["text"] = .string(text) }
            sections.append(Section(context: .browserLink, arguments: arguments, hidden: text.isEmpty ? ["browser.link.copyText"] : []))
        }
        if let image = target.imageURL {
            sections.append(Section(context: .browserImage, arguments: ["url": .string(image.absoluteString)], hidden: []))
        }
        if !target.isEditable, !target.selection.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            sections.append(Section(context: .browserSelection, arguments: ["text": .string(target.selection)], hidden: []))
        }
        return sections
    }

    /// The rows for `target` on the page of tab `tab`, a separator between
    /// sections. `searchEngine` names the omnibar's engine in the Search
    /// row.
    @MainActor
    static func items(for target: BrowserContextMenuTarget, tab: ActionTargetRef, registry: ActionRegistry,
                      searchEngine: String) -> [NSMenuItem] {
        var items: [NSMenuItem] = []
        for section in sections(for: target) {
            let menu = registry.makeContextMenu(
                for: section.context, target: tab,
                entries: registry.contextMenuEntries(for: section.context, removing: section.hidden),
                implied: .browserFocused, arguments: section.arguments
            )
            let rows = menu.items
            menu.removeAllItems()
            guard !rows.isEmpty else { continue }
            if !items.isEmpty { items.append(.separator()) }
            items += rows
        }
        for item in items {
            guard let id = ActionRegistry.menuRun(of: item)?.id,
                  let title = title(of: id, for: target, searchEngine: searchEngine) else { continue }
            item.title = title
        }
        return items
    }

    /// Pure: the title Chrome gives row `id` for `target` when it differs
    /// from the action's own: the selection quoted in Search and Look Up,
    /// Copy Email Address for a `mailto:` link. Nil keeps the action's title.
    static func title(of id: ActionID, for target: BrowserContextMenuTarget, searchEngine: String) -> String? {
        switch id {
        case "browser.selection.search": BrowserHitStrings.search(engine: searchEngine, snippet(target.selection))
        case "browser.selection.lookUp": BrowserHitStrings.lookUp(snippet(target.selection))
        case "browser.link.copy" where target.linkURL?.scheme?.lowercased() == "mailto": BrowserHitStrings.copyEmailAddress
        default: nil
        }
    }

    /// Pure: `text` on one line, at most `limit` characters (Chrome's
    /// menu rows quote the selection the same way).
    static func snippet(_ text: String, limit: Int = 50) -> String {
        let line = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return line.count > limit ? String(line.prefix(limit - 1)) + "…" : line
    }
}
