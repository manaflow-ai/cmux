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

    func canOpenInBrowser(_ fileURL: URL) -> Bool {
        let pathExtension = fileURL.pathExtension.lowercased()
        guard fileURL.isFileURL,
              pathExtension == "html" || pathExtension == "htm",
              BrowserAvailabilitySettings.isEnabled(defaults: defaults)
        else {
            return false
        }
        return true
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
}
