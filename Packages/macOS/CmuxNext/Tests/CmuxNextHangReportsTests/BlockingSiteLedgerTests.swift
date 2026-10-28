import CmuxNextCompat
@testable import CmuxNextHangReports
import Foundation
import Testing

/// ``BlockingSiteLedger``: each report carries the main thread's blocking calls since the
/// last queued one, by hashed site id, and a call is sent once (Chrome's snapshot deltas).
struct BlockingSiteLedgerTests {
    /// The detector's cumulative sites and reset count, as a test sets them.
    final class Detector: Sendable {
        private let current = Mutex(BlockingDetector.MainThreadRead())

        func set(_ sites: [BlockingSite]) { current.withLock { $0.sites = sites } }
        /// `debug.blocking reset`: the counters go to zero and the reset count goes up.
        func reset() {
            current.withLock { read in
                read.resets += 1
                read.sites = read.sites.map { BlockingSite(kind: $0.kind, location: $0.location, count: 0, context: $0.context) }
            }
        }
        var sites: BlockingDetector.MainThreadRead { current.withLock { $0 } }
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

    /// After a `debug.blocking reset` every call counted is new, whether the count climbed back past its old
    /// baseline or not: the reset count says so, not the values.
    @Test(arguments: [(2, UInt64(1_000_000)), (30, UInt64(200_000_000)), (12, UInt64(40_000_000))])
    func afterAResetEveryCallIsNew(count: Int, nanos: UInt64) {
        let detector = Detector()
        let ledger = BlockingSiteLedger(sites: { detector.sites })
        detector.set([Self.site(Self.store, 10, nanos: 50_000_000)])
        ledger.commit(ledger.take())
        detector.reset()
        detector.set([Self.site(Self.store, count, nanos: nanos)])
        let taken = ledger.take()
        #expect(taken.sites == [HangReport.BlockingSiteCount(site: Self.id(Self.store), kind: "file-io", count: count,
                                                             totalMs: Int(nanos / 1_000_000))])
        ledger.commit(taken)
        detector.set([Self.site(Self.store, count + 1, nanos: nanos + 1_000_000)])
        #expect(ledger.take().sites.map(\.count) == [1])
    }

    /// A reset also rebases the sites the last report did not send: all of their counts since it are new.
    @Test func aResetRebasesTheSitesAReportDidNotSend() {
        let detector = Detector()
        let ledger = BlockingSiteLedger(sites: { detector.sites })
        let sites = (1 ... HangReport.maxBlockingSites + 1).map { "CmuxNextApp/Sites.swift:\($0)" }
        detector.set(sites.enumerated().map { Self.site($1, 100 + $0) })
        ledger.commit(ledger.take())
        detector.reset()
        detector.set([Self.site(sites[0], 40)])
        #expect(ledger.take().sites.map(\.count) == [40])
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

    /// A report sends at most ``HangReport/maxBlockingSites`` sites; the ones it cut keep their counts for the next
    /// report, so every call is sent once (the server's per-site totals are whole).
    @Test func theSitesAReportCutAreSentByTheNextOne() {
        let detector = Detector()
        let ledger = BlockingSiteLedger(sites: { detector.sites })
        let sites = (1 ... HangReport.maxBlockingSites + 3).map { Self.site("CmuxNextApp/Sites.swift:\($0)", $0) }
        detector.set(sites)
        let first = ledger.take()
        #expect(first.sites.map(\.count) == Array((4 ... HangReport.maxBlockingSites + 3).reversed()))
        ledger.commit(first)
        #expect(ledger.take().sites.map(\.count) == [3, 2, 1])
        // A cut site's calls since keep adding to what it still owes; a sent site counts only its new calls.
        detector.set(sites.map { Self.site($0.location, $0.count + 1) })
        let second = ledger.take()
        #expect(Array(second.sites.map(\.site).prefix(3)) == sites.prefix(3).reversed().map { Self.id($0.location) })
        #expect(second.sites.map(\.count) == [4, 3, 2] + Array(repeating: 1, count: HangReport.maxBlockingSites - 3))
        ledger.commit(second)
        #expect(ledger.take().sites.map(\.count) == [1, 1, 1])
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
