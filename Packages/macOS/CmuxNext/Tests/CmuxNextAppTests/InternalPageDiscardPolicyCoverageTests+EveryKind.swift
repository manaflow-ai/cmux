@testable import CmuxNextApp
import CmuxNextDesign
import CmuxNextHibernation
import CmuxNextMemory
import CmuxNextWakeups
import Foundation
import Testing

extension InternalPageDiscardPolicyCoverageTests {
    /// Every kind of content a tab shows says when its hidden copy may go, so the `memoryDiscard*`
    /// features can release all a person cannot see. Chrome decides every tab's discard eligibility in
    /// one place (chrome/browser/performance_manager/policies/discard_eligibility_policy.cc); cmux's
    /// classes declare theirs in ``TabContentClass/discard``, an exhaustive switch.
    ///
    /// Each page's own policy is proven by calling its provider (batches 1 to 4 of this suite); the
    /// release itself by InternalPageDiscardTests (pages), the browser and agent page hibernation tests,
    /// and the warm set tests (terminals).
    @Suite struct EveryKind {
        #if DEBUG || CMUX_BENCH_HOOKS
        @MainActor @Test func theHomeFixtureIsNeverDiscarded() {
            let fixture = DebugHomeNativeFixture(openPanel: MadeAheadOpenPanel(), deadlines: linklessDeadlines(), work: BackgroundWork(label: "test.home-fixture"))
            #expect(fixture.discardPolicy(for: LocalPageTab.makeKey(.homeNativeFixture)) == .never)
        }
        #endif

        // MARK: Tab content (MQ-CONTENT)

        /// The content kinds a page store's ``ContentDiscardScheduler`` releases (InternalPageTabStore's
        /// `enableDiscards`, which AppServices calls with `memoryDiscardInternalPages` on;
        /// InternalPageDiscardTests proves the release).
        static let scheduledKinds: Set<ContentKind> = [.internalPage]

        /// Each class that claims a kind names one the app releases: a hibernation kind
        /// (``MemoryHistograms/hibernationKinds``) or a scheduled one; the warm set holds terminals only; and
        /// a class nothing releases says why.
        @Test func everyTabContentKindHasADiscardPath() {
            let cases = TabContentClass.allCases
            #expect(cases.count >= 7, "TabContent has 7 cases (MQ-CONTENT); TabContentClass lists \(cases)")
            let hibernated = Set(MemoryHistograms.hibernationKinds)
            for content in cases {
                switch content.discard {
                case .kind(let kind):
                    #expect(hibernated.contains(kind.rawValue) || Self.scheduledKinds.contains(kind), """
                    TabContent.\(content) claims ContentKind.\(kind), but nothing discards that kind: no \
                    hibernation records it and no page store schedules it. Give the kind a discard path, \
                    or declare the class `.never(why:)` in CmuxNextHibernation/TabContentClass.swift.
                    """)
                case .warmSet:
                    #expect(content == .terminal, "the warm set holds terminals only; TabContent.\(content) is not one")
                case .never(let why):
                    #expect(why.split(whereSeparator: \.isWhitespace).count >= 3, "TabContent.\(content) is never discarded without why")
                }
            }
        }
    }
}
