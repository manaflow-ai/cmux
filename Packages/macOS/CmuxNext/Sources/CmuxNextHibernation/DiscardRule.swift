package import CmuxNextSettings

/// One reason ``ContentDiscardPlanner`` keeps content: which kinds and discards it applies to, how
/// strongly it keeps (``CanDiscardResult/protected`` or ``CanDiscardResult/disallowed``) and the fact
/// it reads.
///
/// One check of Chrome's `DiscardEligibilityPolicy::CanDiscard`
/// (chrome/browser/performance_manager/policies/discard_eligibility_policy.cc) per value. Each
/// rule lives in its own file under `Rules/` as a static value on this type, and ``registered``
/// lists them all once, so a new rule adds one file and one line.
///
/// A rule that reads a kind's own policy (`browser.hibernation` for browser pages) applies to that
/// kind only (``kinds``): turning browser hibernation off, or a Never Hibernate host, never keeps a
/// terminal or a conversation. A kind that plans through the planner adds its own policy rule
/// (its `memory.discard.<kind>` switch) the same way.
///
/// ```swift
/// nonisolated extension DiscardRule {
///     package static let pinned = DiscardRule(.pinned, result: .protected, for: DiscardRule.automatic,
///                                             kinds: DiscardRule.browserPages) { candidate, context in
///         candidate.isPinned && !context.browser.includesPinnedTabs
///     }
/// }
/// ```
package nonisolated struct DiscardRule: Sendable {
    /// What a rule reads besides the candidate.
    package nonisolated struct Context: Sendable {
        /// `browser.hibernation`: read only by rules scoped to ``browserPages``.
        package var browser: BrowserHibernationSetting
        /// Why the discard would happen.
        package var reason: DiscardReason

        package init(browser: BrowserHibernationSetting, reason: DiscardReason) {
            self.browser = browser
            self.reason = reason
        }
    }

    /// The reason reported when the rule matches.
    package let reason: CannotDiscardReason
    /// How strongly a match keeps the content.
    package let result: CanDiscardResult
    /// The discards the rule is checked for.
    package let discardReasons: Set<DiscardReason>
    /// The kinds of content the rule is checked for.
    package let kinds: Set<ContentKind>
    private let test: @Sendable (ContentDiscardPlanner.Candidate, Context) -> Bool
    private let expiry: (@Sendable (ContentDiscardPlanner.Candidate) -> Double?)?

    /// Makes a rule.
    ///
    /// - Parameters:
    ///   - reason: The reason reported when it matches.
    ///   - result: ``CanDiscardResult/protected`` or ``CanDiscardResult/disallowed``.
    ///   - discardReasons: The discards it is checked for.
    ///   - kinds: The kinds it is checked for; every kind unless it reads one kind's policy or facts.
    ///   - test: Whether the candidate matches.
    ///   - expiresIn: For a fact that ends with time alone (``recentlyAudible``), the seconds until it
    ///     stops matching; nil (the default) for a rule only an event ends.
    package init(_ reason: CannotDiscardReason, result: CanDiscardResult, for discardReasons: Set<DiscardReason>,
                 kinds: Set<ContentKind> = DiscardRule.everyKind,
                 test: @escaping @Sendable (ContentDiscardPlanner.Candidate, Context) -> Bool,
                 expiresIn: (@Sendable (ContentDiscardPlanner.Candidate) -> Double?)? = nil) {
        self.reason = reason
        self.result = result
        self.discardReasons = discardReasons
        self.kinds = kinds
        self.test = test
        self.expiry = expiresIn
    }

    /// Whether the rule keeps `candidate` from a discard for `context.reason`: it applies to the
    /// candidate's kind and to that discard, and its fact holds.
    ///
    /// - Parameters:
    ///   - candidate: The content's facts.
    ///   - context: The settings and the discard's reason.
    package func matches(_ candidate: ContentDiscardPlanner.Candidate, _ context: Context) -> Bool {
        kinds.contains(candidate.kind) && discardReasons.contains(context.reason) && test(candidate, context)
    }

    /// Seconds until the rule stops matching `candidate` with time alone, or nil when only an event
    /// ends its fact (the content stops playing, the person closes DevTools).
    ///
    /// - Parameter candidate: Content the rule matches.
    package func expires(_ candidate: ContentDiscardPlanner.Candidate) -> Double? {
        expiry?(candidate)
    }

    /// Every kind of content.
    package static let everyKind = Set(ContentKind.allCases)
    /// Browser pages only: the rules that read `browser.hibernation` or the tab strip.
    package static let browserPages: Set<ContentKind> = [.browser]

    /// The discards a protected rule keeps content from: the timeout and memory pressure.
    package static let pressure: Set<DiscardReason> = [.proactive, .urgent]
    /// The discards a choice of the person keeps content from (`browser.hibernation` off, a pinned
    /// tab, Never Hibernate This Site, open DevTools): every discard cmux makes on its own, a frozen
    /// page's memory growth too (stricter than Chrome, which lets that discard past them).
    package static let automatic: Set<DiscardReason> = [.proactive, .urgent, .frozenWithGrowingMemory]
    /// cmux's lead rule (stricter than Chrome): what the person would lose (audio, capture, input,
    /// a download, an agent's work, a running command) is kept from every discard but the
    /// person's own, including a frozen page's memory growth.
    package static let leadRule: Set<DiscardReason> = [.proactive, .urgent, .frozenWithGrowingMemory]
    /// Every discard, even the person's own.
    package static let always = Set(DiscardReason.allCases)

    /// Every rule, in the order their reasons are reported (the first match is the reason
    /// `debug.surfaces` shows). Browser hibernation reported its reasons in this order before the
    /// planner: the tab strip's neighbor and agent grace first, then the planner's rules, with the page
    /// probe's answers (``PageProbe``) in the probe's own order where it checked capture. The probe's
    /// facts are false until it answers, so they change no plan made before it. Keep new rules after
    /// these.
    package static let registered: [DiscardRule] = [
        .neighbor,
        .agentDriving,
        .disabled,
        .unsupported,
        .agentLease,
        .downloading,
        .formSubmission,
        .devTools,
        .capturing,
        .audio,
        .formInput,
        .unreadableFrame,
        .beforeUnload,
        .webRTC,
        .connectedDevice,
        .webAudio,
        .pinned,
        .excluded,
        .unsavedEdits,
        .runningCommand,
        .notifications,
        .unanswered,
        .backgroundActivity,
        .recentlyAudible,
        .activeTab,
        .discardAttempted,
    ]
}
