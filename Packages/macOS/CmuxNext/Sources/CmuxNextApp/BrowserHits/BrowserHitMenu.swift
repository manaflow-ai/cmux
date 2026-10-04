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
        // Red: no rows yet.
        []
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
                entries: ContextMenuCatalog.shared.entries(for: section.context, removing: section.hidden),
                implied: .browserFocused, arguments: section.arguments
            )
            let rows = menu.items
            menu.removeAllItems()
            guard !rows.isEmpty else { continue }
            if !items.isEmpty { items.append(.separator()) }
            items += rows
        }
        let snippet = snippet(target.selection)
        for item in items {
            guard let id = ActionRegistry.menuRun(of: item)?.id else { continue }
            switch id {
            case "browser.selection.search": item.title = BrowserHitStrings.search(engine: searchEngine, snippet)
            case "browser.selection.lookUp": item.title = BrowserHitStrings.lookUp(snippet)
            default: break
            }
        }
        return items
    }

    /// Pure: `text` on one line, at most `limit` characters (Chrome's
    /// menu rows quote the selection the same way).
    static func snippet(_ text: String, limit: Int = 50) -> String {
        let line = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return line.count > limit ? String(line.prefix(limit - 1)) + "…" : line
    }
}
