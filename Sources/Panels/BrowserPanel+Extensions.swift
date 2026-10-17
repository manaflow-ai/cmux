import AppKit
import CmuxBrowser

extension BrowserPanel {
    /// The panel's Chromium extension host, or nil for a WebKit panel (or a
    /// Chromium page set up without extensions).
    var extensionHost: (any BrowserExtensionHosting)? {
        (enginePage as? any BrowserExtensionHostProviding)?.extensionHost
    }

    /// The page view's leading edge in window coordinates (extension popups anchor to it).
    func extensionPageLeadingX() -> CGFloat? {
        guard let view = enginePage?.contentView, view.window != nil else { return nil }
        return view.convert(view.bounds, to: nil).minX
    }

    /// The enabled third-party extensions that can reach the panel's current
    /// page. Automation that reads or drives page content must refuse while
    /// this is non-empty (``BrowserExtensionAgentAccess``); WebKit panels
    /// have no extensions and return an empty list.
    func extensionAutomationBlockers(
        access: BrowserExtensionAgentAccess = .fromDisk(
            trustedBuiltInFolder: BrowserBuiltInExtensionTrust(resources: Bundle.main.resourceURL).trustedAdBlockerFolder
        )
    ) -> [BrowserExtensionInfo] {
        guard let host = extensionHost else { return [] }
        let store = host.extensionStore
        store.refresh()
        return access.blockers(store.extensions, url: enginePage?.state.url ?? currentURL)
    }

    /// Runs the Chrome extension shortcut (`chrome.commands`) `event` is, with
    /// this panel's page as the active tab. The shortcut monitor calls it for
    /// a key no cmux shortcut took while this panel is focused (its page, the
    /// address bar or the find bar), as cmux Next's key router does.
    ///
    /// - Returns: False for a WebKit panel, in browser focus mode (every key
    ///   is the page's), and for a key no extension bound.
    func runExtensionShortcut(for event: NSEvent) -> Bool {
        guard let host = extensionHost else { return false }
        return host.extensionStore.runShortcut(for: event, in: host.extensionTab, pageOwnsAllKeys: isBrowserFocusModeActive)
    }

    /// The window of the panel's engine page, if it is on screen.
    var extensionPageWindow: NSWindow? { enginePage?.contentView.window }

    /// Carries out a choice the person made in the Extensions popover. These
    /// are the person's own clicks, so no consent sheet is involved.
    func handleExtensionMenuChoice(_ choice: BrowserExtensionsMenuView.Choice) {
        guard let host = extensionHost else { return }
        let store = host.extensionStore
        switch choice {
        case .run(let id):
            host.extensionTab.requestExtensionAction(id)
        case .pin(let id, let pinned):
            _ = store.setPinned(id, pinned)
        case .options(let id):
            _ = store.openOptions(id, from: host.extensionTab)
        case .setEnabled(let id, let enabled):
            _ = store.setEnabled(id, enabled)
        case .reload(let id):
            _ = store.reload(id)
        case .remove(let id):
            _ = store.uninstall(id)
        case .siteAccess(let id):
            host.showExtensionActionMenu(id, atScreenPoint: NSEvent.mouseLocation)
        case .loadUnpacked:
            presentLoadUnpackedPanel(store: store)
        case .webStore:
            openExtensionPage(.webStore)
        case .manage:
            openExtensionPage(.management)
        }
        host.refreshExtensionActions()
    }

    /// Opens the Chrome Web Store or `chrome://extensions` as a new tab in
    /// this panel's pane, in this panel's engine and profile (the
    /// `browser.engine` setting may be WebKit, where neither page works).
    /// Automation passes `focus: false` (socket focus policy).
    func openExtensionPage(_ page: BrowserExtensionPage, focus: Bool = true) {
        guard let workspace = AppDelegate.shared?.workspaceContainingPanel(
            panelId: id,
            preferredWorkspaceId: workspaceId
        )?.workspace, let paneId = workspace.paneId(forPanelId: id) else { return }
        _ = workspace.newBrowserSurface(
            inPane: paneId,
            url: page.url,
            focus: focus,
            preferredProfileID: profileID,
            engine: engineKind
        )
    }

    private func presentLoadUnpackedPanel(store: BrowserExtensionStore) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = String(localized: "browser.extensions.chooseFolder", defaultValue: "Choose an unpacked extension folder")
        panel.prompt = String(localized: "browser.extensions.load", defaultValue: "Load")
        let completion: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            _ = store.loadUnpacked(at: url.standardizedFileURL.path)
        }
        if let window = extensionPageWindow {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            panel.begin(completionHandler: completion)
        }
    }
}
