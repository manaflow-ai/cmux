/// How long a hidden tab of an internal page keeps its view before `memory.discard.internalPages`
/// releases it (the tab, its title, icon and picture stay; showing it builds the view again).
/// Chrome gives each hidden tab one deadline (chrome/browser/performance_manager/policies/
/// memory_saver_mode_policy.cc); cmux chooses the deadline per page kind
/// (``ContentKind/internalPage``).
package nonisolated struct InternalPageDiscardPolicy: Hashable, Sendable {
    /// Time hidden before the view is released.
    package let hiddenTimeout: Duration
    /// False only for ``undeclared``: the page's owner did not choose a policy
    /// (InternalPageDiscardPolicyCoverageTests).
    package let isDeclared: Bool

    /// Released after `timeout` hidden.
    package static func afterHidden(_ timeout: Duration) -> Self { Self(hiddenTimeout: timeout, isDeclared: true) }

    /// Ten minutes, the value of Chrome's desktop kNonVisiblePagesUrgentProtectionTime
    /// (discard_eligibility_policy.h). Using it as an internal page's deadline is a cmux choice.
    package static let standardTimeout: Duration = .seconds(600)
    /// Released after ten minutes hidden, chosen by the page's owner.
    package static let standard = afterHidden(standardTimeout)
    /// The provider default: the standard timeout, not chosen by the page's owner.
    package static let undeclared = Self(hiddenTimeout: standardTimeout, isDeclared: false)
}
