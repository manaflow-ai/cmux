import Foundation

/// Stores leader key sub-binding configuration (timeout, enable/disable, per-action key overrides).
enum LeaderKeySettings {
    // MARK: - Master Toggle

    static let enabledKey = "leaderKey.enabled"
    static let enabledDefault = false

    static var isEnabled: Bool {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: enabledKey) == nil { return enabledDefault }
        return defaults.bool(forKey: enabledKey)
    }

    // MARK: - Timeout

    static let timeoutKey = "leaderKey.timeout"
    static let timeoutDefault: Double = 0.5
    static let timeoutRange: ClosedRange<Double> = 0.2...3.0

    static var timeout: Double {
        let defaults = UserDefaults.standard
        let value = defaults.double(forKey: timeoutKey)
        if value == 0 { return timeoutDefault }
        return value.clamped(to: timeoutRange)
    }

    // MARK: - Workspace Tags Toggle

    static let workspaceTagsEnabledKey = "workspaceTagsEnabled"
    static let workspaceTagsEnabledDefault = false

    static var workspaceTagsEnabled: Bool {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: workspaceTagsEnabledKey) == nil { return workspaceTagsEnabledDefault }
        return defaults.bool(forKey: workspaceTagsEnabledKey)
    }

    // MARK: - Leader Sub-Actions

    /// All leader key sub-actions with their default key bindings.
    enum LeaderAction: String, CaseIterable, Identifiable {
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

        var id: String { rawValue }

        var defaultsKey: String { "leader.action.\(rawValue)" }

        /// The default key character (what the user presses after the leader key).
        /// Shifted symbols use the produced character; letters use lowercase.
        var defaultKey: String {
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

        var label: String {
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

        /// Display string for the key (human-readable).
        var keyDisplayString: String {
            let k = LeaderKeySettings.key(for: self)
            switch k {
            case "\"": return "\\\""
            case ",": return ","
            case "[": return "["
            default: return k.uppercased()
            }
        }
    }

    /// Non-tab-selector actions shown as configurable rows in settings.
    static let configurableActions: [LeaderAction] = [
        .splitRight, .splitDown, .focusNextPane, .closePane,
        .newTab, .nextTab, .previousTab, .focusLeft, .focusRight, .focusDown, .focusUp,
        .setWorkspaceTag, .toggleCopyMode,
    ]

    // MARK: - Per-Action Key Accessors

    static func key(for action: LeaderAction) -> String {
        UserDefaults.standard.string(forKey: action.defaultsKey) ?? action.defaultKey
    }

    static func setKey(_ key: String, for action: LeaderAction) {
        if key == action.defaultKey {
            UserDefaults.standard.removeObject(forKey: action.defaultsKey)
        } else {
            UserDefaults.standard.set(key, forKey: action.defaultsKey)
        }
    }

    // MARK: - Reset

    static func resetAll() {
        UserDefaults.standard.removeObject(forKey: enabledKey)
        UserDefaults.standard.removeObject(forKey: timeoutKey)
        UserDefaults.standard.removeObject(forKey: workspaceTagsEnabledKey)
        for action in LeaderAction.allCases {
            UserDefaults.standard.removeObject(forKey: action.defaultsKey)
        }
    }
}

// MARK: - Comparable Clamping

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
