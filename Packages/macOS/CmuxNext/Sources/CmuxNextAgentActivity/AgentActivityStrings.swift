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
        t("pane.empty.detail", "Sessions and their steps show here when an agent uses the computer.")
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
    static var unwatch: String { t("action.unwatch", "Stop Watching") }
    static var export: String { t("action.export", "Export") }
    static var more: String { t("action.more", "More") }
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

    static var layout: String { t("layout.title", "Layout") }
    static var layoutSplit: String { t("layout.split", "Split") }
    static var layoutTimeline: String { t("layout.timeline", "Timeline") }
    static var layoutGrid: String { t("layout.grid", "Grid") }

    // The lanes view (cx-v9k2f).
    static var lanes: String { t("lanes.title", "Lanes") }
    static var computerUse: String { t("lanes.computerUse", "Computer use") }
    static var pageView: String { t("lanes.view", "View") }
    static var laneWorking: String { t("lanes.state.working", "Working") }
    static var laneInput: String { t("lanes.state.input", "Waiting on you") }
    static var laneIdle: String { t("lanes.state.idle", "Idle") }
    static var laneFailed: String { t("lanes.state.failed", "Failed") }
    static var laneLost: String { t("lanes.state.lost", "Lost") }
    static var lanesOwn: String { t("lanes.own", "On their own") }
    /// `{count}` is the number of sessions; the page fills it in.
    static var lanesAttention: String { t("lanes.attention", "Needs you: {count}") }
    static var lanesEmpty: String { t("lanes.empty", "No agent sessions") }
    static var lanesNoMatch: String { t("lanes.noMatch", "No matching sessions") }
    /// A lane's state and how long it has been in it; the page fills both in.
    static var laneStatus: String { t("lanes.status", "{state} · {duration}") }

    /// Every string the web page shows, by the key the page reads (`model.ts` `strings`).
    static var page: [String: String] {
        [
            "title": title, "filter": filter, "emptyTitle": emptyTitle, "emptyDetail": emptyDetail,
            "noFrame": noFrame, "active": status(.active), "idle": status(.idle), "paused": status(.paused),
            "live": live, "stop": stop, "pause": pause, "resume": resume, "watch": watch, "unwatch": unwatch,
            "thisMac": thisMac, "layout": layout, "layoutSplit": layoutSplit, "layoutTimeline": layoutTimeline,
            "layoutGrid": layoutGrid, "notStarted": connection(.notStarted) ?? "",
            "notSetUp": connection(.notSetUp) ?? "", "unreachable": connection(.unreachable) ?? "",
            "lanes": lanes, "computerUse": computerUse, "pageView": pageView, "laneWorking": laneWorking,
            "laneInput": laneInput, "laneIdle": laneIdle, "laneFailed": laneFailed, "laneLost": laneLost,
            "lanesOwn": lanesOwn, "lanesAttention": lanesAttention, "lanesEmpty": lanesEmpty,
            "lanesNoMatch": lanesNoMatch, "laneStatus": laneStatus,
        ]
    }
}

/// Strings the App needs for the pane (tab title, local machine name).
public nonisolated enum AgentActivityPaneStrings {
    public static var title: String { AgentActivityStrings.title }
    public static var thisMac: String { AgentActivityStrings.thisMac }
}
