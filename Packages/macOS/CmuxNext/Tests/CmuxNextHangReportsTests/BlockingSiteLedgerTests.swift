import CmuxNextCompat
@testable import CmuxNextHangReports
import Foundation
import Testing

/// ``BlockingSiteLedger`` (p12-perf-process-226): each report carries the main thread's blocking calls since the
/// last queued one, by hashed site id, and a call is sent once (Chrome's snapshot deltas).
struct BlockingSiteLedgerTests {
    /// The detector's cumulative sites, as a test sets them.
    final class Detector: Sendable {
        private let current = Mutex<[BlockingSite]>([])

        func set(_ sites: [BlockingSite]) { current.withLock { $0 = sites } }
        var sites: [BlockingSite] { current.withLock { $0 } }
    }

    static let store = "CmuxNextApp/WorkspaceStore.swift:42"
    static let sidebar = "CmuxNextSidebar/SidebarModel.swift:9"

    static func site(_ location: String, _ count: Int, nanos: UInt64 = 0, kind: BlockingKind = .fileIO,
                     context: BlockingContext = .main) -> BlockingSite {
        BlockingSite(kind: kind, location: location, count: count, totalNanos: nanos, context: context)
    }

    static func id(_ location: String) -> String { HangReport.BlockingSiteCount.siteID(location: location) }

    @Test func theSiteIDIsTheFirstEightBytesOfTheLocationsSHA256() {
        #expect(Self.id(Self.store) == "8ef2dbd38483c034")
        #expect(Self.id(Self.sidebar) == "2fc36eeebd7c605e")
    }

    /// A take changes nothing; a commit moves the baseline, so the next report has only the calls since.
    @Test func aCommittedTakeSendsOnlyTheCallsSinceIt() {
        let detector = Detector()
        let ledger = BlockingSiteLedger(sites: { detector.sites })
        detector.set([Self.site(Self.store, 4, nanos: 9_000_000), Self.site(Self.sidebar, 6, kind: .sqlite)])
        let first = ledger.take()
        #expect(first.sites.map(\.site) == [Self.id(Self.sidebar), Self.id(Self.store)])
        #expect(first.sites.map(\.totalMs) == [0, 9])
        #expect(ledger.take() == first)
        ledger.commit(first)
        detector.set([Self.site(Self.store, 5, nanos: 11_000_000), Self.site(Self.sidebar, 6, kind: .sqlite)])
        #expect(ledger.take().sites == [HangReport.BlockingSiteCount(site: Self.id(Self.store), kind: "file-io", count: 1, totalMs: 2)])
    }

    /// Only main-thread sites count, and reports turned on send nothing counted before.
    @Test func poolSitesAndCallsBeforeARestartAreNotSent() {
        let detector = Detector()
        let ledger = BlockingSiteLedger(sites: { detector.sites })
        detector.set([Self.site(Self.store, 3), Self.site(Self.sidebar, 8, context: .pool)])
        #expect(ledger.take().sites.map(\.site) == [Self.id(Self.store)])
        ledger.restart()
        #expect(ledger.take().isEmpty)
    }

    /// Counts zeroed since the baseline (`debug.blocking reset`) are new calls, not a negative difference.
    @Test func aCountBelowItsBaselineIsCountedWhole() {
        let detector = Detector()
        let ledger = BlockingSiteLedger(sites: { detector.sites })
        detector.set([Self.site(Self.store, 10)])
        ledger.commit(ledger.take())
        detector.set([Self.site(Self.store, 2)])
        #expect(ledger.take().sites.map(\.count) == [2])
    }

    /// What a quit saves joins the next launch's counts, and goes once.
    @Test func savedCountsCarryToTheNextLaunchAndAreSentOnce() throws {
        let before = Detector()
        let quitting = BlockingSiteLedger(sites: { before.sites })
        before.set([Self.site(Self.store, 3, nanos: 4_000_000)])
        let saved = try JSONDecoder().decode(BlockingSiteLedger.Saved.self, from: JSONEncoder().encode(quitting.saved()))

        let after = Detector()
        let next = BlockingSiteLedger(sites: { after.sites })
        next.restart()
        next.merge(saved)
        after.set([Self.site(Self.store, 2, nanos: 1_000_000)])
        let taken = next.take()
        #expect(taken.sites == [HangReport.BlockingSiteCount(site: Self.id(Self.store), kind: "file-io", count: 5, totalMs: 5)])
        next.commit(taken)
        #expect(next.take().isEmpty)
    }

    /// A report names the sites with the most calls, at most ``HangReport/maxBlockingSites``.
    @Test func aReportNamesTheSitesWithTheMostCalls() {
        let detector = Detector()
        let ledger = BlockingSiteLedger(sites: { detector.sites })
        detector.set((1 ... HangReport.maxBlockingSites + 3).map { Self.site("CmuxNextApp/Sites.swift:\($0)", $0) })
        let counts = ledger.take().sites.map(\.count)
        #expect(counts == Array((4 ... HangReport.maxBlockingSites + 3).reversed()))
    }
}
