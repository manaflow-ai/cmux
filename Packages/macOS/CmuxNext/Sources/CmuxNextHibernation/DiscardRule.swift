package import CmuxNextSettings

/// One reason ``ContentDiscardPlanner`` keeps content: which discards it applies to, how strongly it
/// keeps (``CanDiscardResult/protected`` or ``CanDiscardResult/disallowed``) and the fact it reads.
///
/// One check of Chrome's `DiscardEligibilityPolicy::CanDiscard`
/// (chrome/browser/performance_manager/policies/discard_eligibility_policy.cc) per value. Each
/// rule lives in its own file under `Rules/` as a static value on this type, and ``registered``
/// lists them all once, so a new rule adds one file and one line.
///
/// ```swift
/// nonisolated extension DiscardRule {
///     package static let pinned = DiscardRule(.pinned, result: .protected, for: DiscardRule.pressure) {
///         candidate, context in candidate.isPinned && !context.setting.includesPinnedTabs
///     }
/// }
/// ```
package nonisolated struct DiscardRule: Sendable {
    /// What a rule reads besides the candidate.
    package nonisolated struct Context: Sendable {
        /// `browser.hibernation`.
        package var setting: BrowserHibernationSetting
        /// Why the discard would happen.
        package var reason: DiscardReason

        package init(setting: BrowserHibernationSetting, reason: DiscardReason) {
            self.setting = setting
            self.reason = reason
        }
    }

    /// The reason reported when the rule matches.
    package let reason: CannotDiscardReason
    /// How strongly a match keeps the content.
    package let result: CanDiscardResult
    /// The discards the rule is checked for.
    package let discardReasons: Set<DiscardReason>
    private let test: @Sendable (ContentDiscardPlanner.Candidate, Context) -> Bool

    /// Makes a rule.
    ///
    /// - Parameters:
    ///   - reason: The reason reported when it matches.
    ///   - result: ``CanDiscardResult/protected`` or ``CanDiscardResult/disallowed``.
    ///   - discardReasons: The discards it is checked for.
    ///   - test: Whether the candidate matches.
    package init(_ reason: CannotDiscardReason, result: CanDiscardResult, for discardReasons: Set<DiscardReason>,
                 test: @escaping @Sendable (ContentDiscardPlanner.Candidate, Context) -> Bool) {
        self.reason = reason
        self.result = result
        self.discardReasons = discardReasons
        self.test = test
    }

    /// Whether `candidate` matches the rule.
    ///
    /// - Parameters:
    ///   - candidate: The content's facts.
    ///   - context: The setting and the discard's reason.
    package func matches(_ candidate: ContentDiscardPlanner.Candidate, _ context: Context) -> Bool {
        test(candidate, context)
    }

    /// The discards a protected rule keeps content from: the timeout and memory pressure.
    package static let pressure: Set<DiscardReason> = [.proactive, .urgent]
    /// cmux's lead rule (stricter than Chrome): what the person would lose (audio, capture, input,
    /// a download, an agent's work, a running command) is kept from every discard but the
    /// person's own, including a frozen page's memory growth.
    package static let leadRule: Set<DiscardReason> = [.proactive, .urgent, .frozenWithGrowingMemory]
    /// Every discard, even the person's own.
    package static let always = Set(DiscardReason.allCases)

    /// Every rule, in the order their reasons are reported (the first match is the reason
    /// `debug.surfaces` shows). Browser hibernation reported its reasons in this order before the
    /// planner; keep new rules after them.
    package static let registered: [DiscardRule] = [
        .disabled,
        .unsupported,
        .agentLease,
        .downloading,
        .formSubmission,
        .devTools,
        .capturing,
        .pinned,
        .excluded,
        .unsavedEdits,
        .runningCommand,
        .notifications,
    ]
}
