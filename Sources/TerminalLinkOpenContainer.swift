import Foundation

/// Host operations needed to give terminal links identical behavior in the
/// workspace grid and the Dock.
@MainActor
protocol TerminalLinkOpenContainer: AnyObject {
    var terminalLinkContainerDebugName: String { get }

    func terminalLinkWorkingDirectory(for sourcePanelId: UUID) -> String?
    func terminalLinkIsRemoteTerminal(_ sourcePanelId: UUID) -> Bool

    @discardableResult
    func deferTerminalFileLinkOpen(
        sourcePanelId: UUID,
        filePath: String,
        fallback: @escaping @MainActor @Sendable () -> Void
    ) -> Bool

    @discardableResult
    func openTerminalBrowserLink(url: URL, sourcePanelId: UUID) -> Bool

    @discardableResult
    func openOrFocusTerminalBrowserFileLink(url: URL, sourcePanelId: UUID) -> Bool
}

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
        guard (pathExtension == "html" || pathExtension == "htm"),
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
