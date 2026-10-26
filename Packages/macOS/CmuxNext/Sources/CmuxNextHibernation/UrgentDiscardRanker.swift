/// The one urgent discard pass over every kind of hidden page: browser tabs, agent chats and cmux pages
/// (p13-webui.md section 3.C, task 092; agreed with p07-memory.md section 3.C). Pure: each owner turns
/// its hidden pages into ``Candidate``s with its own eligibility (``HibernationPlanner/urgentCandidates(_:candidates:)``,
/// ``PageLifecyclePlanner/urgentCandidates(_:conditions:)``), the app's critical memory event ranks them
/// together once, and each owner discards its own keys from the ``Pass``.
///
/// The order is Chrome's `PageDiscardingHelper::DiscardMultiplePages`
/// (components/performance_manager/policies/page_discarding_helper.cc, `PageNodeSortProxy`): protected
/// pages after every other one, then the page hidden longest first. A page hidden less than
/// ``protectionWindow`` is protected (Chrome's `kNonVisiblePagesUrgentProtectionTime`), as is one its
/// owner protects; an urgent pass still takes protected pages last (`discard_protected_tabs`). The pass
/// takes pages in that order until their estimated memory reaches the reclaim target; with no target
/// it takes one page, as Chrome's `UrgentPageDiscardingPolicy` discards one page per critical event.
///
/// ```swift
/// let pass = UrgentDiscardRanker().pass(tabs + pages, reclaimTarget: nil)
/// for candidate in pass.discards { owner(of: candidate).discard(candidate.key) }
/// ```
package nonisolated struct UrgentDiscardRanker: Sendable {
    /// One hidden page an urgent pass may discard: its owner found nothing that keeps it.
    package nonisolated struct Candidate: Hashable, Sendable {
        package var key: String
        /// Its kind (a browser tab, an agent chat, a cmux page): the pass reports it, the order ignores it.
        package var kind: ContentKind
        /// Seconds since it was last visible.
        package var hiddenFor: Double
        /// What discarding it frees (its renderers' footprint, shared ones split); nil when not measured,
        /// which counts as nothing toward a reclaim target.
        package var estimatedBytes: UInt64?
        /// Its owner protects it (a probe kept it lately): it goes after every unprotected page.
        package var isProtected: Bool

        package init(key: String, kind: ContentKind, hiddenFor: Double, estimatedBytes: UInt64? = nil, isProtected: Bool = false) {
            self.key = key
            self.kind = kind
            self.hiddenFor = hiddenFor
            self.estimatedBytes = estimatedBytes
            self.isProtected = isProtected
        }
    }

    /// One pass's result.
    package nonisolated struct Pass: Hashable, Sendable {
        /// The pages to discard, in rank order.
        package var discards: [Candidate] = []
        /// The sum of their estimates.
        package var estimatedBytes: UInt64 = 0
        /// The estimates reached the reclaim target (false with no target).
        package var reachedTarget = false

        package init() {}

        package var keys: [String] { discards.map(\.key) }
    }

    /// Seconds hidden under which a page is protected: Chrome's `kNonVisiblePagesUrgentProtectionTime`,
    /// 10 minutes (page_discarding_helper.h). It orders, it never keeps: each owner's own minimum hidden
    /// time keeps the page the person just left.
    package var protectionWindow: Double

    package init(protectionWindow: Double = 600) {
        self.protectionWindow = protectionWindow
    }

    /// The candidate is protected: by its owner, or hidden less than ``protectionWindow``.
    package func isProtected(_ candidate: Candidate) -> Bool {
        candidate.isProtected || candidate.hiddenFor < protectionWindow
    }

    /// `lhs` goes before `rhs`: unprotected first, then the longest hidden, then the key (a stable order).
    package func precedes(_ lhs: Candidate, _ rhs: Candidate) -> Bool {
        let (left, right) = (isProtected(lhs), isProtected(rhs))
        if left != right { return !left }
        return Self.longestHiddenFirst(lhs.hiddenFor, lhs.key, rhs.hiddenFor, rhs.key)
    }

    /// Chrome's order among pages with the same protection, shared with the timed passes
    /// (``PageLifecyclePlanner/plan(_:conditions:)``): the earliest last visible time first, the key
    /// breaking ties.
    package static func longestHiddenFirst(_ lhsHidden: Double, _ lhsKey: String, _ rhsHidden: Double, _ rhsKey: String) -> Bool {
        lhsHidden != rhsHidden ? lhsHidden > rhsHidden : lhsKey < rhsKey
    }

    /// Every candidate in discard order. A key listed twice keeps its first entry.
    package func ranked(_ candidates: [Candidate]) -> [Candidate] {
        var seen = Set<String>()
        return candidates.filter { seen.insert($0.key).inserted }.sorted(by: precedes)
    }

    /// One urgent pass: the ranked candidates until their estimates reach `reclaimTarget`, or the first
    /// one with no target. A target already met (0) discards nothing.
    ///
    /// - Parameters:
    ///   - candidates: Every owner's eligible hidden pages.
    ///   - reclaimTarget: Bytes to free; nil discards one page.
    /// - Returns: The pages to discard, in rank order, and what they free.
    package func pass(_ candidates: [Candidate], reclaimTarget: UInt64?) -> Pass {
        var pass = Pass()
        for candidate in ranked(candidates) {
            if let reclaimTarget, pass.estimatedBytes >= reclaimTarget { break }
            pass.discards.append(candidate)
            let (sum, overflow) = pass.estimatedBytes.addingReportingOverflow(candidate.estimatedBytes ?? 0)
            pass.estimatedBytes = overflow ? .max : sum
            if reclaimTarget == nil { break }
        }
        if let reclaimTarget { pass.reachedTarget = pass.estimatedBytes >= reclaimTarget }
        return pass
    }
}
