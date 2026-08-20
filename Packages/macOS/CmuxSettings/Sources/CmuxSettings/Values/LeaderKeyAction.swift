import Foundation

/// A command invoked by pressing a configured key after the leader prefix.
public enum LeaderKeyAction: String, CaseIterable, Identifiable, Sendable {
    case splitRight
    case splitDown
    case focusNextPane
    case closePane
    case newTab
    case nextTab
    case previousTab
    case focusLeft
    case focusRight
    case focusDown
    case focusUp
    case setWorkspaceTag
    case toggleCopyMode
    case toggleSplitZoom
    case selectTab0
    case selectTab1
    case selectTab2
    case selectTab3
    case selectTab4
    case selectTab5
    case selectTab6
    case selectTab7
    case selectTab8
    case selectTab9

    /// The stable action identifier.
    public var id: String { rawValue }

    /// The legacy `UserDefaults` key used for this action's override.
    public var defaultsKey: String { "leader.action.\(rawValue)" }

    /// The typed setting declaration for this action's key.
    public var settingsKey: DefaultsKey<String> {
        DefaultsKey(
            id: "app.leaderKey.action.\(rawValue)",
            defaultValue: defaultKey,
            userDefaultsKey: defaultsKey
        )
    }

    /// The built-in sub-key used when no override is stored.
    public var defaultKey: String {
        switch self {
        case .splitRight: return "\\"
        case .splitDown: return "-"
        case .focusNextPane: return "o"
        case .closePane: return "x"
        case .newTab: return "c"
        case .nextTab: return "n"
        case .previousTab: return "p"
        case .focusLeft: return "h"
        case .focusRight: return "l"
        case .focusDown: return "j"
        case .focusUp: return "k"
        case .setWorkspaceTag: return ","
        case .toggleCopyMode: return "["
        case .toggleSplitZoom: return "z"
        case .selectTab0: return "0"
        case .selectTab1: return "1"
        case .selectTab2: return "2"
        case .selectTab3: return "3"
        case .selectTab4: return "4"
        case .selectTab5: return "5"
        case .selectTab6: return "6"
        case .selectTab7: return "7"
        case .selectTab8: return "8"
        case .selectTab9: return "9"
        }
    }

    /// The localized action name shown in Leader Key settings.
    public var label: String {
        switch self {
        case .splitRight:
            return String(localized: "leader.action.splitRight.label", defaultValue: "Split Right")
        case .splitDown:
            return String(localized: "leader.action.splitDown.label", defaultValue: "Split Down")
        case .focusNextPane:
            return String(localized: "leader.action.focusNextPane.label", defaultValue: "Focus Next Pane")
        case .closePane:
            return String(localized: "leader.action.closePane.label", defaultValue: "Close Pane")
        case .newTab:
            return String(localized: "leader.action.newTab.label", defaultValue: "New Tab")
        case .nextTab:
            return String(localized: "leader.action.nextTab.label", defaultValue: "Next Tab")
        case .previousTab:
            return String(localized: "leader.action.previousTab.label", defaultValue: "Previous Tab")
        case .focusLeft:
            return String(localized: "leader.action.focusLeft.label", defaultValue: "Focus Left")
        case .focusRight:
            return String(localized: "leader.action.focusRight.label", defaultValue: "Focus Right")
        case .focusDown:
            return String(localized: "leader.action.focusDown.label", defaultValue: "Focus Down")
        case .focusUp:
            return String(localized: "leader.action.focusUp.label", defaultValue: "Focus Up")
        case .setWorkspaceTag:
            return String(localized: "leader.action.setWorkspaceTag.label", defaultValue: "Set Workspace Tag")
        case .toggleCopyMode:
            return String(localized: "leader.action.toggleCopyMode.label", defaultValue: "Toggle Copy Mode")
        case .toggleSplitZoom:
            return String(localized: "leader.action.toggleSplitZoom.label", defaultValue: "Toggle Split Zoom")
        case .selectTab0:
            return String(localized: "leader.action.selectTab0.label", defaultValue: "Select Tab 10")
        case .selectTab1:
            return String(localized: "leader.action.selectTab1.label", defaultValue: "Select Tab 1")
        case .selectTab2:
            return String(localized: "leader.action.selectTab2.label", defaultValue: "Select Tab 2")
        case .selectTab3:
            return String(localized: "leader.action.selectTab3.label", defaultValue: "Select Tab 3")
        case .selectTab4:
            return String(localized: "leader.action.selectTab4.label", defaultValue: "Select Tab 4")
        case .selectTab5:
            return String(localized: "leader.action.selectTab5.label", defaultValue: "Select Tab 5")
        case .selectTab6:
            return String(localized: "leader.action.selectTab6.label", defaultValue: "Select Tab 6")
        case .selectTab7:
            return String(localized: "leader.action.selectTab7.label", defaultValue: "Select Tab 7")
        case .selectTab8:
            return String(localized: "leader.action.selectTab8.label", defaultValue: "Select Tab 8")
        case .selectTab9:
            return String(localized: "leader.action.selectTab9.label", defaultValue: "Select Tab 9")
        }
    }

    /// Actions exposed as configurable rows in the settings window.
    public static let configurableActions: [Self] = [
        .splitRight, .splitDown, .focusNextPane, .closePane,
        .newTab, .nextTab, .previousTab, .focusLeft, .focusRight, .focusDown, .focusUp,
        .setWorkspaceTag, .toggleCopyMode, .toggleSplitZoom,
    ]
}
