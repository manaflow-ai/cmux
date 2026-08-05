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

    func browserURL(
        for fileURL: URL,
        isAlreadyResolved: Bool = false
    ) -> URL? {
        let pathExtension = fileURL.pathExtension.lowercased()
        guard fileURL.isFileURL,
              pathExtension == "html" || pathExtension == "htm",
              BrowserAvailabilitySettings.isEnabled(defaults: defaults)
        else {
            return nil
        }
        if isAlreadyResolved {
            return fileURL.standardizedFileURL
        }
        return BrowserLocalFileReadAccessPolicy.fileOnly.resolvedNavigationURL(for: fileURL)
    }

    @discardableResult
    func open(
        fileURL: URL,
        sourcePanelId: UUID,
        container: any TerminalLinkOpenContainer
    ) -> Bool {
        guard let browserURL = browserURL(for: fileURL) else { return false }
        return container.openOrFocusTerminalBrowserFileLink(
            resolvedURL: browserURL,
            sourcePanelId: sourcePanelId
        )
    }
}
