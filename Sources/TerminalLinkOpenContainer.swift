import Foundation

/// Host operations needed to give terminal links identical behavior in the
/// workspace grid and the Dock.
@MainActor
protocol TerminalLinkOpenContainer: AnyObject {
    var terminalLinkContainerDebugName: String { get }

    func terminalLinkContainsPanel(_ sourcePanelId: UUID) -> Bool
    func terminalLinkWorkingDirectory(for sourcePanelId: UUID) -> String?
    func terminalLinkHoverWorkingDirectory(for sourcePanelId: UUID) -> String?
    func terminalLinkIsRemoteTerminal(_ sourcePanelId: UUID) -> Bool
    func terminalLinkSnapshotTerminalPanel(for sourcePanelId: UUID) -> TerminalPanel?

    /// Returns whether the container accepted the deferred route. When it does,
    /// `completion` fires once after the panel opens or `fallback` finishes.
    @discardableResult
    func deferTerminalFileLinkOpen(
        sourcePanelId: UUID,
        filePath: String,
        resolvedFileURL: URL?,
        fallback: @escaping @MainActor @Sendable () -> Void,
        completion: @escaping @MainActor @Sendable () -> Void
    ) -> Bool

    @discardableResult
    func openTerminalBrowserLink(url: URL, sourcePanelId: UUID) -> Bool

    @discardableResult
    func openOrFocusTerminalBrowserFileLink(resolvedURL: URL, sourcePanelId: UUID) -> Bool
}

extension TerminalLinkOpenContainer {
    func terminalLinkHoverWorkingDirectory(for sourcePanelId: UUID) -> String? {
        terminalLinkWorkingDirectory(for: sourcePanelId)
    }
}
