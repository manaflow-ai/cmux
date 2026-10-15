import AppKit
import CmuxBrowser

extension BrowserPanel {
    /// The panel's Chromium extension host, or nil for a WebKit panel.
    ///
    /// Chromium pages conform to ``BrowserExtensionHosting``; until the
    /// engine plumbing gives `BrowserPanel` an engine page, every panel is
    /// WebKit and this is nil, so extension commands report that they need
    /// the Chromium engine and the toolbar shows no extension controls.
    var extensionHost: (any BrowserExtensionHosting)? {
        extensionHostingPage as? any BrowserExtensionHosting
    }

    /// The engine page that may host extensions. WebKit-only today.
    private var extensionHostingPage: AnyObject? { nil }

    /// The page view's leading edge in window coordinates (extension popups anchor to it).
    func extensionPageLeadingX() -> CGFloat? {
        guard let view = (extensionHostingPage as? any BrowserPage)?.contentView, view.window != nil else { return nil }
        return view.convert(view.bounds, to: nil).minX
    }

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
        if let window = (extensionHostingPage as? any BrowserPage)?.contentView.window {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            panel.begin(completionHandler: completion)
        }
    }
}
