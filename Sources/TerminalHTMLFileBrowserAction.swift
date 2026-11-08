import Foundation

/// Opens terminal-linked HTML files through the shared browser-panel action.
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
        return container.openTerminalBrowserLink(
            url: browserURL,
            sourcePanelId: sourcePanelId
        )
    }
}
