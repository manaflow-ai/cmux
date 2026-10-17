import AppKit
import Bonsplit
import CmuxBrowser
import CmuxCEF
import CmuxCEFBrowser
import Foundation
import os

/// Places tabs and downloads Chromium starts for no cmux page: an extension's
/// background worker (`chrome.tabs.create`, `chrome.downloads.download`), the
/// welcome page an extension opens after its install, a tab created before
/// any Chromium page exists. Without this they were closed (their URL went to
/// a hook nothing set) or, for downloads, waited forever.
///
/// The active workspace's focused Chromium page (else a shown one) of the
/// request's profile takes the tab into its Chromium window, and it opens
/// beside that page like a link's tab; without one, the URL opens as a new
/// Chromium tab in the focused browser pane, else a new browser pane. None
/// of this activates the app or takes the keyboard from another pane.
///
/// Reference: cmux Next `CmuxNextBrowser/CEF/CEFOrphanTabs.swift`.
@MainActor
enum ChromiumUnownedTabRouter {
    private static let logger = Logger(subsystem: "com.cmuxterm.app", category: "browser.chromium.unowned")

    /// Wires the runtime's hooks (once, at launch).
    static func install(on runtime: CEFRuntime) {
        runtime.unownedTabAnchor = { profile in anchor(profile: profile) }
        runtime.openUnownedURL = { url, disposition, profile in
            open(url, background: disposition == .newBackgroundTab, profile: profile)
        }
    }

    private static var activeWorkspace: Workspace? {
        AppDelegate.shared?.activeTabManagerForCommands()?.selectedWorkspace
    }

    /// The browser panels of `workspace`, pane by pane.
    private static func candidates(in workspace: Workspace) -> [(ChromiumUnownedTabCandidate, BrowserPanel)] {
        let controller = workspace.bonsplitController
        let focused = workspace.focusedPanelId
        return controller.allPaneIds.flatMap { pane -> [(ChromiumUnownedTabCandidate, BrowserPanel)] in
            let selected = controller.selectedTab(inPane: pane).flatMap { workspace.panelIdFromSurfaceId($0.id) }
            return controller.tabs(inPane: pane).compactMap { tab in
                guard let panelID = workspace.panelIdFromSurfaceId(tab.id),
                      let panel = workspace.browserPanel(for: panelID) else { return nil }
                let candidate = ChromiumUnownedTabCandidate(
                    panelID: panelID, paneID: pane.id, profileID: panel.profileID,
                    isChromium: liveBrowser(of: panel) != nil,
                    isFocused: focused == panelID, isSelectedInPane: selected == panelID
                )
                return (candidate, panel)
            }
        }
    }

    private static func liveBrowser(of panel: BrowserPanel) -> CEFBrowser? {
        guard let browser = (panel.enginePage as? CEFBrowserPage)?.browser,
              browser.browserID != nil, !browser.isClosed else { return nil }
        return browser
    }

    private static func anchor(profile: UUID?) -> CEFBrowser? {
        guard let workspace = activeWorkspace else { return nil }
        let found = candidates(in: workspace)
        guard let panelID = ChromiumUnownedTabPlacement.anchor(among: found.map(\.0), profile: profile),
              let panel = found.first(where: { $0.0.panelID == panelID })?.1 else { return nil }
        return liveBrowser(of: panel)
    }

    private static func open(_ url: URL, background: Bool, profile: UUID?) {
        guard let workspace = activeWorkspace else {
            logger.error("No workspace for a Chromium tab without a cmux opener; not opened")
            return
        }
        let found = candidates(in: workspace).map(\.0)
        if let paneUUID = ChromiumUnownedTabPlacement.pane(among: found),
           let pane = workspace.bonsplitController.allPaneIds.first(where: { $0.id == paneUUID }),
           workspace.newBrowserSurface(
               inPane: pane, url: url, focus: background ? false : nil, selectWhenNotFocused: !background,
               preferredProfileID: profile, engine: .chromium
           ) != nil {
            return
        }
        guard let source = workspace.focusedPanelId ?? workspace.panels.keys.sorted(by: { $0.uuidString < $1.uuidString }).first else {
            return
        }
        _ = workspace.newBrowserSplit(
            from: source, orientation: .horizontal, url: url, preferredProfileID: profile, focus: false, engine: .chromium
        )
    }
}
