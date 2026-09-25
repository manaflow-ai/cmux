import Foundation
import CmuxSettings

/// Host operations needed to give terminal links identical behavior in the
/// workspace grid and the Dock.
@MainActor
protocol TerminalLinkOpenContainer: AnyObject {
    var terminalLinkContainerDebugName: String { get }

    func terminalLinkWorkingDirectory(for sourcePanelId: UUID) -> String?
    func terminalLinkIsRemoteTerminal(_ sourcePanelId: UUID) -> Bool

    func deferRemoteTerminalFileLinkOpen(sourcePanelId: UUID, rawValue: String) -> Bool

    func cloudTerminalLinkTarget(url: URL, sourcePanelId: UUID) -> CloudTerminalLinkTarget?

    @discardableResult
    func deferTerminalFileLinkOpen(
        sourcePanelId: UUID,
        filePath: String,
        fallback: @escaping @MainActor @Sendable () -> Void
    ) -> Bool

    @discardableResult
    func openTerminalBrowserLink(url: URL, sourcePanelId: UUID, focus: Bool) -> Bool

    @discardableResult
    func openTerminalBrowserLink(
        url: URL,
        sourcePanelId: UUID,
        focus: Bool,
        splitDirection: BrowserTerminalLinkSplitDirection
    ) -> Bool
}

struct CloudTerminalLinkTarget: Sendable, Equatable {
    let url: URL
}

extension TerminalLinkOpenContainer {
    func deferRemoteTerminalFileLinkOpen(sourcePanelId: UUID, rawValue: String) -> Bool { false }

    func openTerminalBrowserLink(url: URL, sourcePanelId: UUID) -> Bool {
        openTerminalBrowserLink(url: url, sourcePanelId: sourcePanelId, focus: true)
    }

    func openTerminalBrowserLink(
        url: URL,
        sourcePanelId: UUID,
        focus: Bool,
        splitDirection _: BrowserTerminalLinkSplitDirection
    ) -> Bool {
        openTerminalBrowserLink(url: url, sourcePanelId: sourcePanelId, focus: focus)
    }
}
