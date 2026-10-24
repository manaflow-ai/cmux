import CmuxNextBridge
import Foundation
import CmuxNextSettings
import CmuxNextWakeups

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
        /// Times the person showed the tab in the last hour (`BrowserHibernation.focusWindow`).
        var recentFocusCount = 0
        /// The page's memory (its renderers' footprint, shared ones split), when sampled.
        var memoryBytes: UInt64?
        /// A download the page started still runs.
        var isDownloading = false
        /// An agent holds the page's browser lease (its cursor is on it).
        var hasAgentLease = false
        /// The probe kept the page lately (it played or held form input): under pressure it
        /// ranks after the others, so it does not hold up the relief of the rest.
        var recentlyKept = false
    }

    /// How many pages one pass hibernates and how soon the next pass runs while more are due,
    /// so pages never all close at once (a page that wakes meanwhile drops out of the queue).
    struct Pace: Equatable {
        var perPass: Int
        var interval: Double
        /// Pages hidden less than this never go (the person just left them). Without pressure
        /// the timeout alone decides.
        var minimumHidden: Double

        static let normal = Pace(perPass: 2, interval: 5, minimumHidden: 0)
        static let warning = Pace(perPass: 1, interval: 15, minimumHidden: 60)
        static let critical = Pace(perPass: 3, interval: 3, minimumHidden: 10)

        static func at(_ pressure: MemoryPressureLevel) -> Pace {
            switch pressure {
            case .normal: .normal
            case .warning: .warning
            case .critical: .critical
            }
        }
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
        /// Beside a pane's shown tab, or hovered (`browser.keepNeighborTabsAwake`).
        case neighbor
        /// The page did not answer the probe: kept for `BrowserHibernation.unansweredLimit`
        /// probes in a row, then until memory pressure (its form edits are unknown).
        case unanswered
        /// A download the page started still runs.
        case downloading
        /// An agent holds the page's browser lease.
        case agentLease = "agent_lease"
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
        if candidate.hasAgentLease { return .agentLease }
        if candidate.isDownloading { return .downloading }
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
        for candidate in candidates {
            if candidate.hasDevTools || candidate.isCapturing || candidate.hasAgentLease || setting.excludes(host: candidate.host)
                || (candidate.isPinned && !setting.includesPinnedTabs) { continue }
            // The shared rule (`BrowserHibernationSetting.freezeTimeLeft`), as for cmux's own pages.
            // Off (nil) freezes nothing.
            guard let left = setting.freezeTimeLeft(hiddenFor: .seconds(candidate.hiddenFor)) else { return plan }
            if left <= .zero {
                plan.due.append(candidate.key)
            } else {
                plan.nextCheck = min(plan.nextCheck ?? left.inSeconds, left.inSeconds)
            }
        }
        return plan
    }

    /// The share of the timeout each doubling of recent focus buys: at the 30 minute default a
    /// tab shown 15 times in the last hour (4 doublings) hibernates 20 minutes later than one
    /// never shown. A share, not a fixed time, so a short timeout stays short.
    static let focusCreditPerDoubling: Double = 1.0 / 6
    /// Seconds a page's memory counts as extra idleness under memory pressure: one minute per
    /// 100 MB, at most 10. Without pressure memory is not scarce, so it does not count.
    static func memoryCredit(_ bytes: UInt64?) -> Double {
        guard let bytes else { return 0 }
        return min(Double(bytes) / Double(100 << 20), 10) * 60
    }

    /// How idle a page counts as: seconds hidden, plus its memory under pressure, less its
    /// recent focus (a share of `timeout`, the seconds before a page is due). Larger is less valuable: it hibernates first and sooner.
    static func idleness(_ candidate: Candidate, pressure: MemoryPressureLevel, timeout: Double) -> Double {
        let focus = log2(1 + Double(min(max(candidate.recentFocusCount, 0), 63))) * focusCreditPerDoubling * timeout
        let memory = pressure == .normal ? 0 : memoryCredit(candidate.memoryBytes)
        return candidate.hiddenFor + memory - focus
    }

    /// The pages to hibernate now, least valuable first, and when to look again.
    ///
    /// A page is due once its idleness reaches the timeout (`browser.hibernation`; 10 minutes at
    /// most under pressure). Under memory pressure, when no page is due, the least valuable page
    /// hidden at least `Pace.minimumHidden` goes anyway, to relieve it. Each pass takes at most
    /// `Pace.perPass` pages and looks again after `Pace.interval` while more are waiting.
    static func plan(_ setting: BrowserHibernationSetting, pressure: MemoryPressureLevel, candidates: [Candidate]) -> Plan {
        var plan = Plan()
        guard let threshold = threshold(setting, pressure: pressure == .critical ? .warning : pressure) else {
            for candidate in candidates { plan.exemptions[candidate.key] = .disabled }
            return plan
        }
        let pace = Pace.at(pressure)
        var ranked: [(key: String, idleness: Double, hiddenFor: Double, kept: Bool)] = []
        for candidate in candidates {
            if let exemption = exemption(candidate, setting: setting) {
                plan.exemptions[candidate.key] = exemption
                continue
            }
            ranked.append((candidate.key, idleness(candidate, pressure: pressure, timeout: threshold), candidate.hiddenFor,
                           pressure != .normal && candidate.recentlyKept))
        }
        ranked.sort {
            if $0.kept != $1.kept { return !$0.kept }
            return $0.idleness != $1.idleness ? $0.idleness > $1.idleness : $0.key < $1.key
        }
        // A page the person just left never goes, whatever its memory or the mode.
        let oldEnough = ranked.filter { $0.hiddenFor >= pace.minimumHidden }
        // Pages the probe just kept come last: only when no other page can go.
        let fresh = oldEnough.filter { !$0.kept }
        var due = fresh.filter { $0.idleness >= threshold }
        if due.isEmpty, pressure != .normal { due = fresh }
        if due.isEmpty { due = oldEnough.filter { $0.idleness >= threshold } }
        if due.isEmpty, pressure != .normal { due = oldEnough }
        plan.due = due.prefix(pace.perPass).map(\.key)
        if due.count > plan.due.count || (pressure != .normal && !plan.due.isEmpty) {
            plan.nextCheck = pace.interval
        }
        let dueKeys = Set(due.map(\.key))
        for page in ranked where !dueKeys.contains(page.key) {
            let young = pace.minimumHidden - page.hiddenFor
            var wait = max(threshold - page.idleness, young)
            // Under pressure any page old enough is relief: look again once this one is.
            if pressure != .normal { wait = min(wait, max(young, pace.interval)) }
            plan.nextCheck = min(plan.nextCheck ?? .infinity, max(wait, 0.001))
        }
        return plan
    }
}
