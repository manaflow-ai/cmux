package import CmuxNextSettings
import Foundation

/// The one discard planner of every kind of hidden content (p07-memory.md section 3.C): which
/// candidates go now, least valuable first, and when to look again. Pure: its owners feed it facts
/// and a clock reading and perform the result. `HibernationPlanner` wraps it for browser pages with
/// the browser's pace.
///
/// Eligibility is Chrome's `DiscardEligibilityPolicy::CanDiscard`
/// (chrome/browser/performance_manager/policies/discard_eligibility_policy.cc): each
/// ``DiscardRule`` that applies to the discard reason and matches the candidate adds its reason, and
/// the worst result wins. Anything but ``CanDiscardResult/eligible`` keeps the candidate.
///
/// ```swift
/// let planner = ContentDiscardPlanner()
/// let plan = planner.plan(setting, for: .urgent, threshold: 600, pace: pace, candidates: hidden)
/// ```
package nonisolated struct ContentDiscardPlanner: Sendable {
    /// One hidden piece of content that could be discarded.
    package nonisolated struct Candidate: Hashable, Sendable {
        package var key: String
        package var kind: ContentKind
        /// Seconds since the content was last visible.
        package var hiddenFor: Double
        package var host: String?
        package var isPinned = false
        package var hasDevTools = false
        /// Camera or microphone in use (Page Info); the probe finds the rest (`PageProbe.capturing`).
        package var isCapturing = false
        /// The engine can save and restore its history.
        package var canRestore = true
        package var showsFormSubmission = false  // the shown document came from a POST (BR-R1)
        /// Times the person showed the content in the last hour (`BrowserHibernation.focusWindow`).
        package var recentFocusCount = 0
        /// The content's memory (its renderers' footprint, shared ones split), when sampled.
        package var memoryBytes: UInt64?
        /// A download the page started still runs.
        package var isDownloading = false
        /// An agent holds the page's browser lease (its cursor is on it).
        package var hasAgentLease = false
        /// The probe kept the page lately (it played or held form input): under pressure it
        /// ranks after the others, so it does not hold up the relief of the rest.
        package var recentlyKept = false
        /// The page's site may show notifications (its permission is Allow): the timeout keeps it,
        /// memory pressure does not (Chrome's kNotificationsEnabled, proactive discards only).
        package var allowsNotifications = false
        /// The content holds edits the person has not saved.
        package var hasUnsavedEdits = false
        /// A terminal's command still runs.
        package var runsCommand = false
        /// It changed its title or icon while hidden (`PageBackgroundActivity`): the timeout keeps
        /// it and it does not freeze (`HibernationPlanner.freezePlan`), memory pressure does not.
        package var hasBackgroundActivity = false
        /// It still loads: it does not freeze until the load ends (Chrome's kLoading); a discard ignores it.
        package var isLoading = false

        /// The tab sits beside a pane's shown tab or was just hovered (browser pages).
        package var isNeighbor = false
        /// An agent called the page within its grace (browser pages).
        package var isAgentDriving = false
        /// The page a pane shows while its window is off screen (browser pages).
        package var isActiveTab = false

        // The lead rule's facts (p07-memory.md section 3.C). A web page's probe fills them right
        // before a discard (`PageProbe.fill(_:)`); other kinds set them from their own state.

        /// Sound, media its mute silences, or Picture in Picture.
        package var isAudible = false
        /// Seconds since the content last played sound (its sound ended, or a probe heard it); nil
        /// when it never did. ``DiscardRule/recentlyAudible`` keeps it for a minute after.
        package var secondsSinceAudible: Double?
        /// The person's edits in its form fields.
        package var hasFormInput = false
        /// The person moved into a child frame whose fields cannot be read.
        package var hasUnreadableFrame = false
        /// Its `beforeunload` would ask before it unloads.
        package var asksBeforeUnload = false
        /// A connected WebRTC peer connection.
        package var hasWebRTC = false
        /// An open USB, HID or serial device, or a connected Bluetooth GATT server.
        package var hasConnectedDevice = false
        /// A running Web Audio context.
        package var usesWebAudio = false
        /// Its probe got no answer, so its edits are unknown.
        package var isUnanswered = false
        /// It still gets the benefit of the doubt for a missed answer (`PageProbeHistory`).
        package var isDoubted = false

        package init(key: String, kind: ContentKind = .browser, hiddenFor: Double, host: String? = nil, isPinned: Bool = false,
                     hasDevTools: Bool = false, isCapturing: Bool = false, canRestore: Bool = true, showsFormSubmission: Bool = false,
                     recentFocusCount: Int = 0, memoryBytes: UInt64? = nil, isDownloading: Bool = false,
                     hasAgentLease: Bool = false, recentlyKept: Bool = false, allowsNotifications: Bool = false,
                     hasUnsavedEdits: Bool = false, runsCommand: Bool = false) {
            self.key = key
            self.kind = kind
            self.hiddenFor = hiddenFor
            self.host = host
            self.isPinned = isPinned
            self.hasDevTools = hasDevTools
            self.isCapturing = isCapturing
            self.canRestore = canRestore
            self.showsFormSubmission = showsFormSubmission
            self.recentFocusCount = recentFocusCount
            self.memoryBytes = memoryBytes
            self.isDownloading = isDownloading
            self.hasAgentLease = hasAgentLease
            self.recentlyKept = recentlyKept
            self.allowsNotifications = allowsNotifications
            self.hasUnsavedEdits = hasUnsavedEdits
            self.runsCommand = runsCommand
        }
    }

    /// How many candidates one pass discards and how soon the next pass runs while more are due,
    /// so content never all goes at once (content shown meanwhile drops out of the queue).
    package nonisolated struct Pace: Hashable, Sendable {
        package var perPass: Int
        package var interval: Double
        /// Content hidden less than this never goes (the person just left it). Without pressure
        /// the timeout alone decides.
        package var minimumHidden: Double

        package init(perPass: Int, interval: Double, minimumHidden: Double) {
            self.perPass = perPass
            self.interval = interval
            self.minimumHidden = minimumHidden
        }

        /// Chrome's urgent pace, the one for every new kind (p07-memory.md section 3.C): one discard
        /// per critical pressure event (`UrgentPageDiscardingPolicy`,
        /// chrome/browser/performance_manager/policies/urgent_page_discarding_policy.cc), then one
        /// every 5 s while it stays critical. Browser pages keep their own paces
        /// (`HibernationPlanner.pace(at:)`) until task 114 measures both.
        package static let chromeUrgent = Self(perPass: 1, interval: 5, minimumHidden: 0)
    }

    package nonisolated struct Plan: Hashable, Sendable {
        /// Keys to discard now (after the owner's last checks, such as the page probe).
        package var due: [String] = []
        /// Seconds until the next candidate reaches its deadline; nil when none will.
        package var nextCheck: Double?
        /// Why each kept candidate stays: the first matched rule's reason.
        package var exemptions: [String: CannotDiscardReason] = [:]

        package init(due: [String] = [], nextCheck: Double? = nil, exemptions: [String: CannotDiscardReason] = [:]) {
            self.due = due
            self.nextCheck = nextCheck
            self.exemptions = exemptions
        }
    }

    /// The rules, in the order their reasons are reported.
    package var rules: [DiscardRule]

    /// Makes a planner with `rules`.
    ///
    /// - Parameter rules: The rules, in report order; ``DiscardRule/registered`` in the app.
    package init(rules: [DiscardRule] = DiscardRule.registered) {
        self.rules = rules
    }

    /// Whether `candidate` may be discarded for `reason`, and why not.
    ///
    /// - Parameters:
    ///   - candidate: The content's facts.
    ///   - setting: `browser.hibernation` (its switch, exclusions and pinned rule), read only by the
    ///     rules of browser pages.
    ///   - reason: Why the discard would happen.
    /// - Returns: The worst result of the rules that match and their reasons in rule order.
    package func eligibility(of candidate: Candidate, setting: BrowserHibernationSetting, for reason: DiscardReason) -> DiscardEligibility {
        let context = DiscardRule.Context(browser: setting, reason: reason)
        var eligibility = DiscardEligibility()
        var ends: Double? = 0
        for rule in rules where rule.matches(candidate, context) {
            eligibility.result = max(eligibility.result, rule.result)
            eligibility.reasons.append(rule.reason)
            // Kept until the last time-bound rule runs out; a rule only an event ends keeps no deadline.
            ends = ends.flatMap { latest in rule.expires(candidate).map { max(latest, $0) } }
        }
        eligibility.endsIn = eligibility.reasons.isEmpty ? nil : ends
        return eligibility
    }

    /// The share of the timeout each doubling of recent focus buys: at the 30 minute default a
    /// tab shown 15 times in the last hour (4 doublings) hibernates 20 minutes later than one
    /// never shown. A share, not a fixed time, so a short timeout stays short.
    package static let focusCreditPerDoubling: Double = 1.0 / 6

    /// Seconds the content's memory counts as extra idleness under memory pressure: one minute per
    /// 100 MB, at most 10. Without pressure memory is not scarce, so it does not count.
    package static func memoryCredit(_ bytes: UInt64?) -> Double {
        guard let bytes else { return 0 }
        return min(Double(bytes) / Double(100 << 20), 10) * 60
    }

    /// How idle a candidate counts as: seconds hidden, plus its memory for an urgent discard, less
    /// its recent focus (a share of `timeout`, the seconds before it is due). Larger is less
    /// valuable: it goes first and sooner.
    package static func idleness(_ candidate: Candidate, for reason: DiscardReason, timeout: Double) -> Double {
        let focus = log2(1 + Double(min(max(candidate.recentFocusCount, 0), 63))) * focusCreditPerDoubling * timeout
        let memory = reason == .urgent ? memoryCredit(candidate.memoryBytes) : 0
        return candidate.hiddenFor + memory - focus
    }

    /// The candidates to discard now, least valuable first, and when to look again.
    ///
    /// A candidate is due once its idleness reaches `threshold`. For an urgent discard, when none
    /// is due, the least valuable candidate hidden at least `Pace.minimumHidden` goes anyway, to
    /// relieve the pressure. Each pass takes at most `Pace.perPass` and looks again after
    /// `Pace.interval` while more are waiting. A candidate kept only by rules that run out with time
    /// (``DiscardEligibility/endsIn``, Chrome's audio protection) is looked at again once they do and
    /// it would be due, in the same one deadline.
    ///
    /// - Parameters:
    ///   - setting: `browser.hibernation`, read by the rules of browser pages.
    ///   - reason: ``DiscardReason/proactive`` without pressure, ``DiscardReason/urgent`` with it.
    ///   - threshold: Seconds of idleness before a candidate is due.
    ///   - pace: How many go per pass and how often.
    ///   - candidates: The hidden content.
    /// - Returns: The due keys, the next check and each kept candidate's reason.
    package func plan(_ setting: BrowserHibernationSetting, for reason: DiscardReason, threshold: Double, pace: Pace,
                      candidates: [Candidate]) -> Plan {
        var plan = Plan()
        let urgent = reason == .urgent
        var ranked: [(key: String, idleness: Double, hiddenFor: Double, kept: Bool)] = []
        var expiring: [(idleness: Double, hiddenFor: Double, endsIn: Double)] = []
        for candidate in candidates {
            let eligibility = eligibility(of: candidate, setting: setting, for: reason)
            if let kept = eligibility.reason {
                plan.exemptions[candidate.key] = kept
                if let endsIn = eligibility.endsIn {
                    expiring.append((Self.idleness(candidate, for: reason, timeout: threshold), candidate.hiddenFor, endsIn))
                }
                continue
            }
            ranked.append((candidate.key, Self.idleness(candidate, for: reason, timeout: threshold), candidate.hiddenFor,
                           urgent && candidate.recentlyKept))
        }
        ranked.sort {
            if $0.kept != $1.kept { return !$0.kept }
            return $0.idleness != $1.idleness ? $0.idleness > $1.idleness : $0.key < $1.key
        }
        // Content the person just left never goes, whatever its memory or the mode.
        let oldEnough = ranked.filter { $0.hiddenFor >= pace.minimumHidden }
        // Content the probe just kept comes last: only when nothing else can go.
        let fresh = oldEnough.filter { !$0.kept }
        var due = fresh.filter { $0.idleness >= threshold }
        if due.isEmpty, urgent { due = fresh }
        if due.isEmpty { due = oldEnough.filter { $0.idleness >= threshold } }
        if due.isEmpty, urgent { due = oldEnough }
        plan.due = due.prefix(pace.perPass).map(\.key)
        if due.count > plan.due.count || (urgent && !plan.due.isEmpty) {
            plan.nextCheck = pace.interval
        }
        let dueKeys = Set(due.map(\.key))
        for page in ranked where !dueKeys.contains(page.key) {
            let dueIn = Self.secondsUntilDue(page.idleness, hiddenFor: page.hiddenFor, threshold: threshold, pace: pace, urgent: urgent)
            plan.nextCheck = min(plan.nextCheck ?? .infinity, max(dueIn, 0.001))
        }
        for page in expiring {
            let dueIn = Self.secondsUntilDue(page.idleness, hiddenFor: page.hiddenFor, threshold: threshold, pace: pace, urgent: urgent)
            plan.nextCheck = min(plan.nextCheck ?? .infinity, max(dueIn, page.endsIn, 0.001))
        }
        return plan
    }

    /// Seconds until a candidate that is not due now would be: its idleness reaches `threshold` and
    /// it is hidden `Pace.minimumHidden`. Under pressure anything old enough is relief, so it is
    /// looked at again once it is old enough, no sooner than `Pace.interval`.
    private static func secondsUntilDue(_ idleness: Double, hiddenFor: Double, threshold: Double, pace: Pace, urgent: Bool) -> Double {
        let young = pace.minimumHidden - hiddenFor
        let dueIn = max(threshold - idleness, young)
        return urgent ? min(dueIn, max(young, pace.interval)) : dueIn
    }
}
