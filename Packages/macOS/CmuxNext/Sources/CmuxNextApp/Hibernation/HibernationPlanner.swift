import CmuxNextBridge
import Foundation
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
        /// Times the person showed the tab in the last hour (`BrowserHibernation.focusWindow`).
        var recentFocusCount = 0
        /// The page's memory (its renderers' footprint, shared ones split), when sampled.
        var memoryBytes: UInt64?
        /// A download the page started still runs.
        var isDownloading = false
        /// An agent holds the page's browser lease (its cursor is on it).
        var hasAgentLease = false
        /// When the probe last kept the page (it played or held form input) and how many times in
        /// a row it did while hidden; nil when it never did.
        var kept: Kept?
        /// Seconds since the page last became counted in the warm budget (its front went from
        /// `Front.warm` to parked or none); nil when it counted since it hid. The person left it
        /// then, so `overBudgetMinimumHidden` runs from the later of the two.
        var countedFor: Double?
        /// Its pane shows it (off screen: a parked workspace or an off-screen column), so a switch
        /// shows it again: `.warm` stays out of the warm budget, `.parked` counts with
        /// `frontCredit`; nil for a tab no pane shows.
        var front: Front?

        /// The probe kept the page lately (`keptHold(times:)`): under pressure it ranks after
        /// the others, so it does not hold up the relief of the rest. It is live for a reason, so
        /// it neither goes for the warm budget nor holds a place in it. Setting it records one keep now.
        var recentlyKept: Bool {
            get { kept.map { $0.seconds < HibernationPlanner.keptHold(times: $0.times) } ?? false }
            set { kept = newValue ? Kept(seconds: 0, times: 1) : nil }
        }

        /// Seconds the person has been away from the page as the warm budget counts it.
        var budgetAge: Double { min(hiddenFor, countedFor ?? hiddenFor) }
    }

    /// The probe's keeps of a hidden page.
    struct Kept: Hashable {
        /// Seconds since the last keep.
        var seconds: Double
        /// Keeps in a row while hidden (1 after the first).
        var times: Int
    }

    /// Seconds a page the probe kept stays out of the budget after its first keep.
    static let keptBackoff: Double = 60
    /// Seconds a page the probe kept `times` in a row stays out of the budget (and, without
    /// pressure, is not probed again): `keptBackoff`, doubling with each keep up to 32 minutes, so
    /// a page that keeps playing is not thawed and probed again every minute while it stays hidden.
    static func keptHold(times: Int) -> Double {
        keptBackoff * Double(1 << min(max(times, 1) - 1, 5))
    }

    /// How near a hidden tab its pane shows (`NeighborTabs.fronts`) is to the next switch, for the
    /// page warm budget.
    enum Front: Hashable {
        /// Shown by a pane of a workspace on screen (an off-screen column: the next scroll shows it)
        /// or of the workspace left last (the next switch back shows all of them at once). Out of
        /// the budget, as the neighbors are; the timeout still applies. Bounded by two workspaces'
        /// panes, not by the number of workspaces.
        case warm
        /// Shown by a pane of a workspace left before that. Counts in the budget, in one idleness
        /// order with every other page, `frontCredit` less idle.
        case parked
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
        /// Keys to hibernate now (after the probe): at most `Pace.perPass` less the ones in flight.
        var due: [String] = []
        /// Every key due now, before the pace took its share: a probe that ends checks its page
        /// is still among them (budget membership can change back while it runs).
        var allDue: Set<String> = []
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
        guard let threshold = setting.freezeSeconds else { return plan }
        for candidate in candidates {
            if candidate.hasDevTools || candidate.isCapturing || candidate.hasAgentLease || setting.excludes(host: candidate.host)
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

    /// Seconds a page over the warm budget stays hidden before it goes: the person just left it
    /// (a quick look at another tab and back), as `Pace.warning.minimumHidden` says under pressure.
    static let overBudgetMinimumHidden: Double = Pace.warning.minimumHidden

    /// The share of the timeout a parked workspace's shown tab (`Front.parked`) counts as less
    /// idle for the warm budget: as much as one show (`focusCreditPerDoubling`), 5 minutes at the
    /// 30 minute default. A switch back to its workspace shows it, so it is worth more than a tab
    /// left as long ago that nobody shows; but bounded, so a tab the person left a minute ago in
    /// the pane they work in still ranks before a workspace left twenty minutes ago.
    static let frontCreditShare: Double = focusCreditPerDoubling

    /// The pages past the warm budget, least valuable first: all `pages` but the `warmPages` most
    /// valuable, in one order of idleness (larger goes first). A warm front (`Front.warm`) neither
    /// goes for the budget nor holds a place in it; a parked front counts `frontCreditShare` of
    /// `timeout` less idle. Shared by browser pages (`plan`) and agent chat pages
    /// (`AgentPageHibernation`); nil `warmPages` means no budget.
    static func overBudget(_ pages: [(key: String, idleness: Double, front: Front?)], warmPages: Int?, timeout: Double) -> [String] {
        guard let warmPages else { return [] }
        let credit = frontCreditShare * timeout
        var counted: [(key: String, rank: Double)] = []
        for page in pages where page.front != .warm {
            counted.append((page.key, page.front == .parked ? page.idleness - credit : page.idleness))
        }
        counted.sort { $0.rank != $1.rank ? $0.rank > $1.rank : $0.key < $1.key }
        return counted.prefix(max(0, counted.count - warmPages)).map(\.key)
    }

    /// The share of `due` (in order) one pass starts, with `inFlight` pages still being
    /// prepared from earlier passes, and whether more wait for the next pass (`Pace.interval`).
    /// Shared by browser pages (`plan`) and chat pages (`AgentPageHibernation`), so a switch that
    /// moves many pages past the budget starts a few jobs, not one per page, however many events
    /// it sends.
    static func paced(_ due: [String], inFlight: Int, pace: Pace) -> (now: [String], more: Bool) {
        let now = Array(due.prefix(max(0, pace.perPass - inFlight)))
        return (now, due.count > now.count)
    }

    /// The pages to hibernate now, least valuable first, and when to look again.
    ///
    /// A page is due once its idleness reaches the timeout (`browser.hibernation`; 10 minutes at
    /// most under pressure). Under memory pressure, when no page is due, the least valuable page
    /// hidden at least `Pace.minimumHidden` goes anyway, to relieve it. Past the warm budget
    /// (`warmPages`, `WarmSetBudget.pageCapacity`: hidden live pages kept beyond the probe's
    /// keeps and the warm fronts, `overBudget`) the least valuable pages are due once the person
    /// has been away from them `overBudgetMinimumHidden` (`Candidate.budgetAge`), so hidden pages
    /// cost a bounded amount, not 55 MB each for half an hour. Each pass takes at most
    /// `Pace.perPass` pages, less the `inFlight` ones still being prepared, and looks again after
    /// `Pace.interval` while more are waiting.
    static func plan(_ setting: BrowserHibernationSetting, pressure: MemoryPressureLevel, candidates: [Candidate],
                     warmPages: Int? = nil, inFlight: Int = 0) -> Plan {
        var plan = Plan()
        guard let threshold = threshold(setting, pressure: pressure == .critical ? .warning : pressure) else {
            for candidate in candidates { plan.exemptions[candidate.key] = .disabled }
            return plan
        }
        let pace = Pace.at(pressure)
        // `kept`: under pressure, ranks last. `held`: without pressure, seconds until the probe is
        // asked again (a kept page is not probed again on every event past its timeout).
        var ranked: [(key: String, idleness: Double, hiddenFor: Double, kept: Bool, held: Double?, budgeted: Bool, front: Front?, budgetAge: Double)] = []
        for candidate in candidates {
            if let exemption = exemption(candidate, setting: setting) {
                plan.exemptions[candidate.key] = exemption
                continue
            }
            let held = candidate.kept.flatMap { kept -> Double? in
                let left = keptHold(times: kept.times) - kept.seconds
                return pressure == .normal && left > 0 ? left : nil
            }
            ranked.append((candidate.key, idleness(candidate, pressure: pressure, timeout: threshold), candidate.hiddenFor,
                           pressure != .normal && candidate.recentlyKept, held, !candidate.recentlyKept, candidate.front, candidate.budgetAge))
        }
        ranked.sort {
            if $0.kept != $1.kept { return !$0.kept }
            return $0.idleness != $1.idleness ? $0.idleness > $1.idleness : $0.key < $1.key
        }
        // Past the budget: every page it counts but the `warmPages` most valuable, parked
        // workspaces' shown tabs in the same order (with a bounded credit): hidden-page memory is
        // bounded by the budget and two workspaces' panes, not by the number of workspaces.
        let byKey = Dictionary(ranked.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        let over = overBudget(ranked.filter { $0.budgeted }.map { (key: $0.key, idleness: $0.idleness, front: $0.front) }, warmPages: warmPages, timeout: threshold)
            .compactMap { byKey[$0] }
        let overKeys = Set(over.map(\.key))
        let overMinimum = max(pace.minimumHidden, overBudgetMinimumHidden)
        // A page the person just left never goes, whatever its memory or the mode.
        let oldEnough = ranked.filter { $0.hiddenFor >= pace.minimumHidden && $0.held == nil }
        // Pages the probe just kept come last: only when no other page can go.
        let fresh = oldEnough.filter { !$0.kept }
        var due = fresh.filter { $0.idleness >= threshold }
        if due.isEmpty, pressure != .normal { due = fresh }
        if due.isEmpty { due = oldEnough.filter { $0.idleness >= threshold } }
        if due.isEmpty, pressure != .normal { due = oldEnough }
        // The timed ones first (least valuable first), then the ones past the budget in budget order.
        let timedKeys = Set(due.map(\.key))
        due += over.filter { $0.budgetAge >= overMinimum && !timedKeys.contains($0.key) }
        let dueKeys = Set(due.map(\.key))
        plan.allDue = dueKeys
        let pass = paced(due.map(\.key), inFlight: inFlight, pace: pace)
        plan.due = pass.now
        if pass.more || (pressure != .normal && !plan.due.isEmpty) {
            plan.nextCheck = pace.interval
        }
        for page in ranked where !dueKeys.contains(page.key) {
            let young = pace.minimumHidden - page.hiddenFor
            var wait = max(threshold - page.idleness, young)
            // Under pressure any page old enough is relief: look again once this one is.
            if pressure != .normal { wait = min(wait, max(young, pace.interval)) }
            // Over the budget: due once the person has been away from it long enough.
            if overKeys.contains(page.key) { wait = min(wait, overMinimum - page.budgetAge) }
            // Kept by the probe: asked again once its backoff ends.
            if let held = page.held { wait = max(wait, held) }
            plan.nextCheck = min(plan.nextCheck ?? .infinity, max(wait, 0.001))
        }
        return plan
    }
}
