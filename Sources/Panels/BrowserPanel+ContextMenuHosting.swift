import AppKit
import CmuxBrowser

/// The cmux rows a Chromium page's context menu shows, the same actions the WebKit menu adds
/// (design spec §11). A WebKit page never asks: its menu is built by `CmuxWebView`.
extension BrowserPanel: BrowserContextMenuHosting {
    func contextMenuDefaultBrowserLink(for target: BrowserContextMenuTarget) -> URL? {
        guard let link = target.linkURL else { return nil }
        let scheme = link.scheme?.lowercased() ?? ""
        return scheme == "http" || scheme == "https" ? link : nil
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
