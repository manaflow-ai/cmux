import AppKit
import CmuxNextBookmarks
import CmuxNextBrowser
import CmuxNextPalette
import Foundation

/// "Open Bookmark…": a palette page of every bookmark of the focused tab's
/// browser profile, searched by the palette's fuzzy matcher on title, URL
/// and folder path.
@MainActor
enum BookmarkPalettePages {
    static func open(_ services: AppServices) -> PalettePageSpec {
        let profile = BookmarkResolver(services: services).profile(.init())
        let provider = AsyncPaletteProvider(id: "bookmark.open") { [weak services] in
            guard let services else { return [] }
            let tree = services.bookmarks.tree(profile)
            return tree.bookmarks.map { item(for: $0, tree: tree, profile: profile, services: services) }
        }
        return PalettePageSpec(id: "bookmark.open", title: BookmarkAppStrings.openTitle, placeholder: BookmarkAppStrings.openPlaceholder,
                               symbol: "star", providers: [provider])
    }

    private static func item(for node: BookmarkNode, tree: BookmarkTree, profile: String, services: AppServices) -> PaletteItem {
        let opener = BookmarkOpener(services: services)
        let url = node.url.map(BookmarkURL.displayText) ?? ""
        let path = tree.folderPath(of: node.id).map { component in
            switch BookmarkRoot(rawValue: component) {
            case .bar: BookmarkStrings.barTitle
            case .other: BookmarkStrings.otherBookmarks
            case nil: component
            }
        }.joined(separator: " › ")
        let secondary = [
            PaletteCommand(id: "newTab", title: BookmarkAppStrings.openInNewTab, symbol: "plus.square",
                           effect: .perform { opener.open(node, profile: profile, disposition: .newTab) }),
            PaletteCommand(id: "copy", title: BookmarkAppStrings.copyURL, symbol: "doc.on.doc", effect: .perform {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(node.url?.absoluteString ?? "", forType: .string)
            }),
            PaletteCommand(id: "manager", title: BookmarkAppStrings.showInManager, symbol: "book.closed",
                           effect: .perform { services.bookmarkPages.open(selecting: node.id) }),
            PaletteCommand(id: "delete", title: BookmarkAppStrings.delete, symbol: "trash", isDestructive: true,
                           effect: .performKeepingOpen { try? services.bookmarks.apply(.delete(id: node.id), profile: profile) }),
        ]
        return PaletteItem(
            id: node.id, title: node.displayTitle, subtitle: url, accessory: path, symbol: "star", keywords: [url, path],
            primary: PaletteCommand(id: "open", title: BookmarkAppStrings.open, symbol: "return",
                                    effect: .perform { opener.open(node, profile: profile, disposition: .currentTab) }),
            secondary: secondary)
    }
}
