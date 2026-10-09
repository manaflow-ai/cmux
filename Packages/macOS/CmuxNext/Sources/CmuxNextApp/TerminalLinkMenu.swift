import AppKit
import CmuxNextActions

/// The link rows of a terminal right-click (cx-k9go): a right-click on a web
/// link Ghostty underlines offers the page link rows (Open Link in New Tab,
/// in New Window, in Split Right, Copy Link, ...) from the `browserLink`
/// placements, the same catalog actions a page's link menu, the palette and
/// the CLI run. With a terminal tab as the target they open in that tab's
/// pane on the default engine. Rows that need a page (Save Link As…) or the
/// link's text are left out.
@MainActor
enum TerminalLinkMenu {
    /// Rows a terminal link cannot fill.
    static let pageOnly: Set<ActionID> = ["browser.link.saveAs", "browser.link.copyText"]

    static func items(for link: URL?, target: ActionTargetRef?, registry: ActionRegistry) -> [NSMenuItem] {
        guard let link, link.scheme == "http" || link.scheme == "https" else { return [] }
        let menu = registry.makeContextMenu(
            for: .browserLink, target: target,
            entries: ContextMenuCatalog.shared.entries(for: .browserLink, removing: pageOnly),
            arguments: ["url": .string(link.absoluteString)]
        )
        let rows = menu.items
        menu.removeAllItems()
        return rows.isEmpty ? [] : rows + [.separator()]
    }
}
