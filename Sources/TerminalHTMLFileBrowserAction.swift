import Foundation

/// Shared HTML-file action used by both Ghostty's direct Command-click
/// fallback and the terminal-link coordinator.
@MainActor
struct TerminalHTMLFileBrowserAction {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func browserURL(for fileURL: URL) -> URL? {
        let pathExtension = fileURL.pathExtension.lowercased()
        guard fileURL.isFileURL,
              pathExtension == "html" || pathExtension == "htm",
              BrowserAvailabilitySettings.isEnabled(defaults: defaults) else {
            return nil
        }
        return fileURL.standardizedFileURL.resolvingSymlinksInPath()
    }

    @discardableResult
    func open(
        fileURL: URL,
        sourcePanelId: UUID,
        container: any TerminalLinkOpenContainer
    ) -> Bool {
        guard let browserURL = browserURL(for: fileURL) else { return false }
        return container.openOrFocusTerminalBrowserFileLink(
            url: browserURL,
            sourcePanelId: sourcePanelId
        )
    }
}
