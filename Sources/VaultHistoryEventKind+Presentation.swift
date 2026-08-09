import CmuxVaultHistory
import Foundation

extension VaultHistoryEventKind {
    var label: String {
        switch self {
        case .workspaceCreated:
            String(localized: "vaultHistory.kind.workspaceCreated", defaultValue: "Workspace created")
        case .workspaceRenamed:
            String(localized: "vaultHistory.kind.workspaceRenamed", defaultValue: "Workspace renamed")
        case .workspaceClosed:
            String(localized: "vaultHistory.kind.workspaceClosed", defaultValue: "Workspace closed")
        case .windowOpened:
            String(localized: "vaultHistory.kind.windowOpened", defaultValue: "Window opened")
        case .windowClosed:
            String(localized: "vaultHistory.kind.windowClosed", defaultValue: "Window closed")
        case .sessionActivity:
            String(localized: "vaultHistory.kind.sessionActivity", defaultValue: "Agent session")
        }
    }

    var symbolName: String {
        switch self {
        case .workspaceCreated: "plus.square"
        case .workspaceRenamed: "pencil"
        case .workspaceClosed: "xmark.square"
        case .windowOpened: "macwindow.badge.plus"
        case .windowClosed: "macwindow"
        case .sessionActivity: "sparkles"
        }
    }
}
