public import Foundation

/// Composes a Chromium page's context menu for cmux Classic: Chromium's own model (its link,
/// image, selection, edit, extension, spelling and Inspect rows) with Classic's cmux rows in the
/// places the WebKit menu has them.
///
/// - "Open Link in Default Browser" follows "Open Link in New Tab".
/// - Chromium's "Search Google for …" row becomes a row that searches with cmux's configured
///   search engine, as the omnibar does.
/// - Chromium rows Classic cannot honor (new Chromium windows, incognito) are removed.
/// - Host groups (screenshots, Move Tab to New Workspace, Browser Focus Mode) follow, each after
///   a separator, as on WebKit.
/// - No menu starts or ends with a separator or shows two in a row.
///
/// ```swift
/// let entries = BrowserChromiumContextMenuComposer().compose(
///     items: BrowserContextMenuItem.decodeChromiumList(itemsJSON),
///     target: BrowserContextMenuTarget(chromiumParamsJSON: paramsJSON),
///     defaultBrowserLink: link,
///     hostGroups: [[.screenshotPage, .screenshotSection], [.moveTabToNewWorkspace]]
/// )
/// ```
public struct BrowserChromiumContextMenuComposer: Sendable {
    /// Command ids removed from the engine's model.
    public var hiddenCommands: Set<Int>

    /// Creates a composer.
    /// - Parameter hiddenCommands: Engine command ids to remove. Defaults to
    ///   ``BrowserChromiumContextMenuCommand/hiddenInClassic``.
    public init(hiddenCommands: Set<Int> = BrowserChromiumContextMenuCommand.hiddenInClassic) {
        self.hiddenCommands = hiddenCommands
    }

    /// Composes the menu rows.
    /// - Parameters:
    ///   - items: Chromium's menu model.
    ///   - target: What was right-clicked (kept for host rows that depend on it).
    ///   - defaultBrowserLink: The link to offer in the default browser, or `nil` when the host
    ///     cannot open the target's link there.
    ///   - webSearch: The cmux search that replaces Chromium's selection search rows, or `nil`
    ///     to keep Chromium's.
    ///   - hostGroups: cmux rows after the engine's, one group per separator-delimited section.
    /// - Returns: The menu's rows in order.
    public func compose(
        items: [BrowserContextMenuItem],
        target: BrowserContextMenuTarget,
        defaultBrowserLink: URL?,
        webSearch: BrowserContextMenuWebSearch? = nil,
        hostGroups: [[BrowserContextMenuHostAction]]
    ) -> [BrowserContextMenuEntry] {
        var entries: [BrowserContextMenuEntry] = filtered(items).map { item in
            item.kind == .separator ? .separator : .engine(item)
        }
        if let webSearch {
            entries = Self.replacingWebSearch(in: entries, with: webSearch)
        }
        if let link = defaultBrowserLink, target.linkURL != nil {
            let openInNewTab = entries.firstIndex { entry in
                if case .engine(let item) = entry {
                    return item.id == BrowserChromiumContextMenuCommand.openLinkInNewTab.rawValue
                }
                return false
            }
            if let openInNewTab {
                entries.insert(.host(.openLinkInDefaultBrowser(link)), at: openInNewTab + 1)
            } else {
                entries.insert(contentsOf: [.host(.openLinkInDefaultBrowser(link)), .separator], at: 0)
            }
        }
        for group in hostGroups where !group.isEmpty {
            entries.append(.separator)
            entries.append(contentsOf: group.map(BrowserContextMenuEntry.host))
        }
        return Self.normalizingSeparators(entries)
    }

    /// Puts `search` where Chromium's first selection search row was and drops the others.
    private static func replacingWebSearch(
        in entries: [BrowserContextMenuEntry],
        with search: BrowserContextMenuWebSearch
    ) -> [BrowserContextMenuEntry] {
        var placed = false
        return entries.compactMap { entry in
            guard case .engine(let item) = entry,
                  BrowserChromiumContextMenuCommand.webSearch.contains(item.id) else { return entry }
            defer { placed = true }
            return placed ? nil : .host(.searchWeb(search))
        }
    }

    private func filtered(_ items: [BrowserContextMenuItem]) -> [BrowserContextMenuItem] {
        items.compactMap { item in
            guard item.kind == .separator || !hiddenCommands.contains(item.id) else { return nil }
            guard item.kind == .submenu else { return item }
            var submenu = item
            submenu.children = filtered(item.children)
            return submenu.children.contains(where: { $0.kind != .separator }) ? submenu : nil
        }
    }

    /// Drops leading, trailing and doubled separators.
    /// - Parameter entries: Menu rows.
    /// - Returns: The rows with clean separators.
    static func normalizingSeparators(_ entries: [BrowserContextMenuEntry]) -> [BrowserContextMenuEntry] {
        var result: [BrowserContextMenuEntry] = []
        for entry in entries {
            if entry == .separator, result.last.map({ $0 == .separator }) ?? true { continue }
            result.append(entry)
        }
        if result.last == .separator { result.removeLast() }
        return result
    }
}
