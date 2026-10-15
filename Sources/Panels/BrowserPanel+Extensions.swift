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
            openLinkInNewTab(url: BrowserExtensionPage.webStore.url)
        case .manage:
            openLinkInNewTab(url: BrowserExtensionPage.management.url)
        }
        host.refreshExtensionActions()
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
