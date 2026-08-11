import CmuxBrowser
import Foundation

/// Shared HTML-file action used by both Ghostty's direct Command-click
/// fallback and the terminal-link coordinator.
@MainActor
struct TerminalHTMLFileBrowserAction {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    nonisolated static func canOpenInBrowser(
        _ fileURL: URL,
        defaults: UserDefaults = .standard
    ) -> Bool {
        let pathExtension = fileURL.pathExtension.lowercased()
        guard fileURL.isFileURL,
              pathExtension == "html" || pathExtension == "htm",
              BrowserAvailabilitySettings.isEnabled(defaults: defaults)
        else {
            return false
        }
        return true
    }

    func canOpenInBrowser(_ fileURL: URL) -> Bool {
        Self.canOpenInBrowser(fileURL, defaults: defaults)
    }

    func browserURL(
        for fileURL: URL,
        resolvedFileURL: URL
    ) -> URL? {
        guard canOpenInBrowser(fileURL) else { return nil }
        return BrowserLocalFileReadAccessPolicy.fileOnly.navigationURL(
            for: fileURL,
            resolvedFileURL: resolvedFileURL
        )
    }

    @discardableResult
    func open(
        fileURL: URL,
        resolvedFileURL: URL,
        sourcePanelId: UUID,
        container: any TerminalLinkOpenContainer
    ) -> Bool {
        guard let browserURL = browserURL(
            for: fileURL,
            resolvedFileURL: resolvedFileURL
        ) else { return false }
        return container.openOrFocusTerminalBrowserFileLink(
            resolvedURL: browserURL,
            sourcePanelId: sourcePanelId
        )
    }

    static func openOrFocusResolvedFile(
        _ resolvedURL: URL,
        browserPanels: [BrowserPanel],
        focusExisting: (BrowserPanel) -> Void,
        createBrowser: () -> BrowserPanel?
    ) -> Bool {
        guard let identity = BrowserLocalFileIdentity(resolvedURL: resolvedURL) else {
            return false
        }
        if let existing = browserPanels.first(where: {
            $0.canReuseTerminalFile(resolvedURL, identity: identity)
        }), existing.openValidatedTerminalFile(
            resolvedURL,
            identity: identity,
            cachePolicy: .reloadIgnoringLocalCacheData
        ) {
            focusExisting(existing)
            return true
        }
        guard let browser = createBrowser() else { return false }
        return browser.openValidatedTerminalFile(
            resolvedURL,
            identity: identity
        )
    }
}
