public import Foundation

/// The panel side of a page context menu the engine asks the host to show (Chromium): which cmux
/// rows to add and how to run them.
///
/// The browser panel conforms and sets itself on a ``BrowserPageContextMenuCustomizing`` page,
/// so the cmux rows are the same ones it adds to WebKit's menu.
@MainActor
public protocol BrowserContextMenuHosting: AnyObject {
    /// The link to offer in the default browser, or `nil` when it cannot open there.
    /// - Parameter target: What was right-clicked.
    /// - Returns: The link.
    func contextMenuDefaultBrowserLink(for target: BrowserContextMenuTarget) -> URL?

    /// The search that replaces the engine's selection search row: the omnibar's search engine.
    /// - Parameter target: What was right-clicked.
    /// - Returns: The search, or `nil` to keep the engine's row.
    func contextMenuWebSearch(for target: BrowserContextMenuTarget) -> BrowserContextMenuWebSearch?

    /// The cmux rows after the engine's, one group per separator-delimited section.
    /// - Parameter target: What was right-clicked.
    /// - Returns: The groups, in order.
    func contextMenuHostGroups(for target: BrowserContextMenuTarget) -> [[BrowserContextMenuHostAction]]

    /// Runs a cmux row the user chose.
    /// - Parameter action: The action.
    func performContextMenuHostAction(_ action: BrowserContextMenuHostAction)
}
