import CmuxRemoteSession
import CmuxTerminal
import Foundation

@MainActor
extension RemoteTmuxSessionMirror {
    /// Forwards one ordered manual-I/O event after validating pane ownership.
    func sendManualInput(_ input: TerminalManualInput, toPane tmuxPaneID: Int) {
        switch input {
        case .bytes(let data):
            _ = sendInputBytes(data, toPane: tmuxPaneID)
        case .namedKey(let name):
            guard let key = RemoteTmuxKeyName(rawName: name) else {
                #if DEBUG
                cmuxDebugLog(
                    "remote.input.namedKey.unresolved pane=\(tmuxPaneID) name=\(name)"
                )
                #endif
                return
            }
            _ = sendNamedKey(key, toPane: tmuxPaneID)
        }
    }

    /// Sends bytes only while the pane remains part of this session mirror.
    func sendInputBytes(_ data: Data, toPane tmuxPaneID: Int) -> Bool {
        guard controlPaneIdByPane[tmuxPaneID] != nil else { return false }
        return connection.sendKeys(paneId: tmuxPaneID, data: data)
    }

    /// Sends a validated key only while the pane remains part of this session mirror.
    func sendNamedKey(_ key: RemoteTmuxKeyName, toPane tmuxPaneID: Int) -> Bool {
        guard controlPaneIdByPane[tmuxPaneID] != nil else { return false }
        return connection.sendKey(paneId: tmuxPaneID, key: key)
    }
}
