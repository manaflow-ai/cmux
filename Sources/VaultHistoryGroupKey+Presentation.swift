import CmuxVaultHistory
import Foundation

extension VaultHistoryGroupKey {
    var label: String {
        switch self {
        case .date:
            String(localized: "vaultHistory.group.date", defaultValue: "Date")
        case .workspace:
            String(localized: "vaultHistory.group.workspace", defaultValue: "Workspace")
        case .window:
            String(localized: "vaultHistory.group.window", defaultValue: "Window")
        case .agent:
            String(localized: "vaultHistory.group.agent", defaultValue: "Agent")
        case .kind:
            String(localized: "vaultHistory.group.kind", defaultValue: "Type")
        }
    }

    var symbolName: String {
        switch self {
        case .date: "clock"
        case .workspace: "square.on.square"
        case .window: "macwindow"
        case .agent: "person.2"
        case .kind: "tag"
        }
    }
}
