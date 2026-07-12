import CmuxMobileShell
import CmuxMobileSupport

struct MobileMacUpdateFeatureDisplay {
    static func name(for feature: MobileMacUpdateFeature) -> String {
        switch feature {
        case .workspaceActions:
            L10n.string("mobile.macUpdateHint.feature.workspaceActions", defaultValue: "Rename and pin workspaces")
        case .workspaceReadState:
            L10n.string("mobile.macUpdateHint.feature.workspaceReadState", defaultValue: "Mark workspaces read or unread")
        case .workspaceClose:
            L10n.string("mobile.macUpdateHint.feature.workspaceClose", defaultValue: "Close workspaces")
        case .workspaceGroups:
            L10n.string("mobile.macUpdateHint.feature.workspaceGroups", defaultValue: "Workspace groups")
        case .workspaceMove:
            L10n.string("mobile.macUpdateHint.feature.workspaceMove", defaultValue: "Reorder workspaces")
        case .workspaceGroupActions:
            L10n.string("mobile.macUpdateHint.feature.workspaceGroupActions", defaultValue: "Move and group workspaces")
        case .workspaceCreateInGroup:
            L10n.string("mobile.macUpdateHint.feature.workspaceCreateInGroup", defaultValue: "Create workspaces inside groups")
        case .workspaceGroupCreate:
            L10n.string("mobile.macUpdateHint.feature.workspaceGroupCreate", defaultValue: "Create workspace groups")
        }
    }
}
