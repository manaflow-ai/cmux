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

    @discardableResult
    func deferTerminalFileLinkOpen(
        sourcePanelId: UUID,
        filePath: String,
        fallback: @escaping @MainActor @Sendable () -> Void
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
