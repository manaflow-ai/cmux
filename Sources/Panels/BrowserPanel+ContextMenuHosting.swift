import AppKit
import CmuxBrowser
import CmuxSettings

/// The cmux rows a Chromium page's context menu shows, the same actions the WebKit menu adds
/// (design spec §11). A WebKit page never asks: its menu is built by `CmuxWebView`.
extension BrowserPanel: BrowserContextMenuHosting {
    func contextMenuDefaultBrowserLink(for target: BrowserContextMenuTarget) -> URL? {
        guard let link = target.linkURL else { return nil }
        let scheme = link.scheme?.lowercased() ?? ""
        return scheme == "http" || scheme == "https" ? link : nil
    }

    /// Chromium's "Search Google for …" row searches with the omnibar's search engine instead.
    func contextMenuWebSearch(for target: BrowserContextMenuTarget) -> BrowserContextMenuWebSearch? {
        let query = target.selection.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return nil }
        let configuration = BrowserSearchSettingsStore().currentConfiguration
        guard let url = configuration.searchURL(query: query) else { return nil }
        return BrowserContextMenuWebSearch(engineName: configuration.displayName, query: query, url: url)
    }

    func contextMenuHostGroups(for target: BrowserContextMenuTarget) -> [[BrowserContextMenuHostAction]] {
        var groups: [[BrowserContextMenuHostAction]] = []
        // Screenshot Page / Section capture through the WebKit snapshot pipeline; Chromium pages
        // get them once that pipeline captures engine pages.
        if canMoveToNewWorkspaceFromContextMenu {
            groups.append([.moveTabToNewWorkspace])
        }
        if isBrowserFocusModeActive || canToggleBrowserFocusMode {
            groups.append([.toggleFocusMode(isActive: isBrowserFocusModeActive)])
        }
        return groups
    }

    func performContextMenuHostAction(_ action: BrowserContextMenuHostAction) {
        switch action {
        case .openLinkInDefaultBrowser(let url):
            _ = NSWorkspace.shared.open(url)
        case .searchWeb(let search):
            // Chromium opens its own search row in a new tab; so does the cmux row.
            openContextMenuLinkInNewTab(url: search.url)
        case .moveTabToNewWorkspace:
            guard let app = AppDelegate.shared, let target = app.browserActionTarget(for: self),
                  BrowserActionDispatcher(appDelegate: app).perform(.moveToNewWorkspace, on: target) else {
                NSSound.beep()
                return
            }
        case .toggleFocusMode:
            if !toggleBrowserFocusMode(reason: "contextMenu", focusWebView: true) {
                NSSound.beep()
            }
        case .screenshotPage, .screenshotSection:
            NSSound.beep()
        }
    }

    private var canMoveToNewWorkspaceFromContextMenu: Bool {
        guard let app = AppDelegate.shared, let target = app.browserActionTarget(for: self) else { return false }
        return BrowserActionDispatcher(appDelegate: app).canMoveBrowserToNewWorkspace(target: target)
    }
}
