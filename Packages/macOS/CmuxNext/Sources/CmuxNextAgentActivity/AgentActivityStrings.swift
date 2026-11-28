import Foundation

/// Strings of the Agent activity pane (Resources/Localizable.xcstrings).
nonisolated enum AgentActivityStrings {
    private static func t(_ key: StaticString, _ value: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: value, bundle: .module)
    }

    static var title: String { t("pane.title", "Agent Activity") }
    static var filter: String { t("pane.filter", "Filter") }
    static var emptyTitle: String { t("pane.empty.title", "No computer use yet") }
    static var emptyDetail: String {
        t("pane.empty.detail", "When an agent uses computer use, its session and a timeline of every action appear here.")
    }
    static var selectSession: String { t("pane.selectSession", "Select a session") }
    static var noFrame: String { t("pane.noFrame", "No screenshot for this step") }
    static var frameExpired: String { t("pane.frameExpired", "Screenshot removed by retention") }
    static var live: String { t("pane.live", "Live") }
    static var typedTextHidden: String { t("pane.typedTextHidden", "Typed text hidden") }

    static var stop: String { t("action.stop", "Stop") }
    static var pause: String { t("action.pause", "Pause") }
    static var resume: String { t("action.resume", "Resume") }
    static var watch: String { t("action.watch", "Watch") }
    static var export: String { t("action.export", "Export") }
    static var openAgent: String { t("action.openAgent", "Open Agent") }
    static var openTarget: String { t("action.openTarget", "Open Target") }

    static func status(_ status: AgentActivityStatus) -> String {
        switch status {
        case .active: t("status.active", "Active")
        case .idle: t("status.idle", "Idle")
        case .paused: t("status.paused", "Paused")
        case let .ended(reason):
            switch reason {
            case .agentEnd: t("status.ended.agent", "Ended")
            case .userStop: t("status.ended.user", "Stopped by you")
            case .idleTTL: t("status.ended.idle", "Timed out")
            case .hostRestart: t("status.ended.restart", "Host restarted")
            case .policy: t("status.ended.policy", "Ended by policy")
            }
        }
    }

    static func attribution(_ attribution: AgentActivityAttribution) -> String? {
        switch attribution {
        case .credential: nil
        case .processTree: t("attribution.processTree", "Matched by process")
        case .none: t("attribution.none", "Unattributed")
        }
    }

    static func connection(_ connection: AgentActivityConnection) -> String? {
        switch connection {
        case .connected: nil
        case .notStarted: t("connection.notStarted", "Computer use has not run here yet")
        case .notSetUp: t("connection.notSetUp", "Computer use needs Accessibility and Screen Recording")
        case .unreachable: t("connection.unreachable", "Machine unreachable")
        }
    }

    static var thisMac: String { t("machine.thisMac", "This Mac") }
    static var foregroundOnly: String { t("pane.foregroundOnly", "Foreground only") }
}

/// Strings the App needs for the pane (tab title, local machine name).
public nonisolated enum AgentActivityPaneStrings {
    public static var title: String { AgentActivityStrings.title }
    public static var thisMac: String { AgentActivityStrings.thisMac }
}
