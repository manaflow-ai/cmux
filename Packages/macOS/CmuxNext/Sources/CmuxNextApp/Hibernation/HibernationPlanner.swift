import CmuxNextBridge
import CmuxNextSettings

/// Which hidden pages hibernate now, and when to look again
/// (plans/cmux-next/tab-lifecycle.md). Pure: the App feeds it facts and a
/// clock reading; `BrowserHibernation` performs the result.
struct HibernationPlanner {
    /// One hidden page that could hibernate.
    struct Candidate: Hashable {
        var key: String
        /// Seconds since the page was last visible.
        var hiddenFor: Double
        var host: String?
        var isPinned = false
        var hasDevTools = false
        /// Camera or microphone in use (Page Info); the probe finds the rest (`PageProbe.capturing`).
        var isCapturing = false
        /// The engine can save and restore its history.
        var canRestore = true
        var showsFormSubmission = false  // the shown document came from a POST (BR-R1)
    }

    /// Why a page does not hibernate (reported by `debug.surfaces`).
    enum Exemption: String, Hashable {
        case disabled, excluded, pinned, devTools = "devtools", capturing, unsupported
        /// Found by the probe right before hibernating.
        case audio, formInput = "form_input"
        /// A running Web Audio context; not under critical memory pressure.
        case webAudio = "web_audio"
        /// An agent chat whose agent works or waits on the person (AgentPageHibernation).
        case agentBusy = "agent_busy"
        /// The acpmux turn watch is down, so no chat's turn is known: every chat counts as busy.
        case agentTurnsUnknown = "agent_turns_unknown"
        case formSubmission = "form_submission"  // the page shows a form result (BR-R1)
        /// An agent called the page within `BrowserHibernation.agentGrace` (`cmux browser`, MCP, the REPL).
        case agentDriving = "agent_driving"
    }

    struct Plan: Equatable {
        /// Keys to hibernate now (after the probe).
        var due: [String] = []
        /// Seconds until the next page reaches its deadline; nil when none will.
        var nextCheck: Double?
        var exemptions: [String: Exemption] = [:]
    }

    /// Seconds hidden before a page hibernates; nil means never.
    static func threshold(_ setting: BrowserHibernationSetting, pressure: MemoryPressureLevel) -> Double? {
        guard let minutes = setting.hiddenMinutes else { return nil }
        switch pressure {
        case .normal: return minutes * 60
        case .warning: return setting.mode == .aggressive ? 0 : min(minutes, 10) * 60
        case .critical: return 0
        }
    }

    static func exemption(_ candidate: Candidate, setting: BrowserHibernationSetting) -> Exemption? {
        if !setting.isEnabled { return .disabled }
        if !candidate.canRestore { return .unsupported }
        if candidate.showsFormSubmission { return .formSubmission }
        if candidate.hasDevTools { return .devTools }
        if candidate.isCapturing { return .capturing }
        if candidate.isPinned, !setting.includesPinnedTabs { return .pinned }
        if setting.excludes(host: candidate.host) { return .excluded }
        return nil
    }

    /// Which hidden pages freeze now, and when the next one will: after
    /// `freezeSeconds` hidden, whatever the hibernation mode, except pinned
    /// tabs (unless they hibernate too), excluded hosts, open DevTools and capture.
    static func freezePlan(_ setting: BrowserHibernationSetting, candidates: [Candidate]) -> Plan {
        var plan = Plan()
        guard let threshold = setting.freezeSeconds else { return plan }
        for candidate in candidates {
            if candidate.hasDevTools || candidate.isCapturing || setting.excludes(host: candidate.host)
                || (candidate.isPinned && !setting.includesPinnedTabs) { continue }
            let remaining = threshold - candidate.hiddenFor
            if remaining <= 0 {
                plan.due.append(candidate.key)
            } else {
                plan.nextCheck = min(plan.nextCheck ?? remaining, remaining)
            }
        }
        return plan
    }

    static func plan(_ setting: BrowserHibernationSetting, pressure: MemoryPressureLevel, candidates: [Candidate]) -> Plan {
        var plan = Plan()
        guard let threshold = threshold(setting, pressure: pressure) else {
            for candidate in candidates { plan.exemptions[candidate.key] = .disabled }
            return plan
        }
        for candidate in candidates.sorted(by: { $0.hiddenFor > $1.hiddenFor }) {
            if let exemption = exemption(candidate, setting: setting) {
                plan.exemptions[candidate.key] = exemption
                continue
            }
            let remaining = threshold - candidate.hiddenFor
            if remaining <= 0 {
                plan.due.append(candidate.key)
            } else {
                plan.nextCheck = min(plan.nextCheck ?? remaining, remaining)
            }
        }
        return plan
    }
}
