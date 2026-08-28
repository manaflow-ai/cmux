import Bonsplit
import Foundation

extension Workspace {
    /// Lands a Harbor row (an attachable tmux/zellij/screen/zmx/herdr/cmux-tui
    /// session, local or on an SSH host) where it was dropped.
    ///
    /// Primary path: provision a daemon terminal that runs the tool's attach
    /// command under the app's cmux-tui daemon, then attach the new pane to it
    /// through the manual-IO pump — the same data path as daemon-backed
    /// terminal tabs, so the attach survives app quit/reopen. When the
    /// manual-IO beta is off (or provisioning fails), fall back to a plain
    /// local terminal running the same attach command, which still works but
    /// is app-owned.
    @discardableResult
    func handleHarborSessionDrop(
        session: HarborSession,
        destination: BonsplitController.ExternalTabDropRequest.Destination
    ) -> Bool {
        let shellCommand = HarborAttachCommand.shellCommand(for: session)
#if DEBUG
        cmuxDebugLog("harbor.drop workspace=\(id.uuidString.prefix(5)) session=\(session.id)")
#endif
        if TuiTerminalAttachBridge.isManualIOEnabled,
           let terminalID = TuiTerminalAttachBridge.shared.provisionHarborTerminal(
               shellCommand: shellCommand,
               terminalName: HarborAttachCommand.terminalName(for: session)
           ) {
            switch destination {
            case .insert(let paneId, _):
                return newTerminalSurface(
                    inPane: paneId,
                    focus: true,
                    tuiManualIOReattachTerminalID: terminalID
                ) != nil
            case .split(let paneId, let orientation, let insertFirst):
                return splitPaneWithNewTerminal(
                    targetPane: paneId,
                    orientation: orientation,
                    insertFirst: insertFirst,
                    workingDirectory: nil,
                    initialInput: nil,
                    tuiManualIOReattachTerminalID: terminalID
                ) != nil
            }
        }
#if DEBUG
        cmuxDebugLog("harbor.drop.fallback session=\(session.id) manualIO=\(TuiTerminalAttachBridge.isManualIOEnabled ? 1 : 0)")
#endif
        switch destination {
        case .insert(let paneId, _):
            return newTerminalSurface(
                inPane: paneId,
                focus: true,
                initialCommand: shellCommand
            ) != nil
        case .split(let paneId, let orientation, let insertFirst):
            return splitPaneWithNewTerminal(
                targetPane: paneId,
                orientation: orientation,
                insertFirst: insertFirst,
                workingDirectory: nil,
                initialInput: nil,
                remoteStartupCommand: shellCommand
            ) != nil
        }
    }

    /// The context-menu / double-click entrypoint: attach into the focused
    /// pane of this workspace as a new tab.
    @discardableResult
    func attachHarborSessionInFocusedPane(session: HarborSession) -> Bool {
        guard let paneId = bonsplitController.focusedPaneId ?? bonsplitController.allPaneIds.first else {
            return false
        }
        return handleHarborSessionDrop(session: session, destination: .insert(targetPane: paneId, targetIndex: nil))
    }
}
