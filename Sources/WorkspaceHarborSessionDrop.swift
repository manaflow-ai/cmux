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
        handleHarborItemDrop(item: .legacySession(session), destination: destination)
    }

    /// Lands one Harbor tree item. A terminal leaf keeps its target identity
    /// in the attach command, so dragging a pane never silently broadens to an
    /// unrelated session.
    @discardableResult
    func handleHarborItemDrop(
        item: HarborDragItem,
        destination: BonsplitController.ExternalTabDropRequest.Destination
    ) -> Bool {
        let shellCommand = HarborAttachCommand.shellCommand(for: item)
#if DEBUG
        cmuxDebugLog("harbor.drop workspace=\(id.uuidString.prefix(5)) item=\(item.title)")
#endif
        if TuiTerminalAttachBridge.isManualIOEnabled,
           let terminalID = TuiTerminalAttachBridge.shared.provisionHarborTerminal(
               shellCommand: shellCommand,
               terminalName: HarborAttachCommand.terminalName(for: item)
           ) {
            switch destination {
            case .insert(let paneId, _):
                let created = newTerminalSurface(
                    inPane: paneId,
                    focus: true,
                    tuiManualIOReattachTerminalID: terminalID
                ) != nil
                if !created {
                    TuiTerminalAttachBridge.shared.closeProvisionedHarborTerminal(terminalID: terminalID)
                }
                return created
            case .split(let paneId, let orientation, let insertFirst):
                let created = splitPaneWithNewTerminal(
                    targetPane: paneId,
                    orientation: orientation,
                    insertFirst: insertFirst,
                    workingDirectory: nil,
                    initialInput: nil,
                    tuiManualIOReattachTerminalID: terminalID
                ) != nil
                if !created {
                    TuiTerminalAttachBridge.shared.closeProvisionedHarborTerminal(terminalID: terminalID)
                }
                return created
            }
        }
#if DEBUG
        cmuxDebugLog("harbor.drop.fallback item=\(item.title) manualIO=\(TuiTerminalAttachBridge.isManualIOEnabled ? 1 : 0)")
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
                    initialCommand: shellCommand
                ) != nil
        }
    }

    /// The context-menu / double-click entrypoint: attach into the focused
    /// pane of this workspace as a new tab.
    @discardableResult
    func attachHarborSessionInFocusedPane(session: HarborSession) -> Bool {
        attachHarborItemInFocusedPane(item: .legacySession(session))
    }

    /// Attaches a terminal leaf or a session-level fallback in the selected
    /// workspace. This is the shared action used by Harbor double-click,
    /// Return, and context-menu commands.
    @discardableResult
    func attachHarborItemInFocusedPane(item: HarborDragItem) -> Bool {
        guard let paneId = bonsplitController.focusedPaneId ?? bonsplitController.allPaneIds.first else {
            return false
        }
        return handleHarborItemDrop(item: item, destination: .insert(targetPane: paneId, targetIndex: nil))
    }
}
