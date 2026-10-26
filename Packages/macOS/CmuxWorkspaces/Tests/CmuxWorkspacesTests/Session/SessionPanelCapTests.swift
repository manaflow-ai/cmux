import Foundation
import Testing
@testable import CmuxWorkspaces

@Suite("SessionPanelCap")
struct SessionPanelCapTests {
    /// Pins the default to the 512 documented in `docs/session-snapshots.md`.
    @Test("The session snapshot policy keeps 512 panels")
    func sessionSnapshotPolicyKeeps512Panels() {
        #expect(SessionPanelCap.sessionSnapshotMaxPanels == 512)
        #expect(SessionPanelCap().maxPanels == 512)
    }

    /// Fewer ids than the cap come back unchanged with no omission.
    @Test("Under the cap every id is retained and nothing is omitted")
    func underTheCapRetainsEveryId() {
        let ids = (0..<3).map { _ in UUID() }
        let result = SessionPanelCap(maxPanels: 4).cap(ids)
        #expect(result.retainedPanelIds == ids)
        #expect(result.omittedCount == 0)
    }

    /// The boundary: exactly `sessionSnapshotMaxPanels` ids is not an omission.
    @Test("Exactly at the cap every id is retained and nothing is omitted")
    func atTheCapRetainsEveryId() {
        let ids = (0..<SessionPanelCap.sessionSnapshotMaxPanels).map { _ in UUID() }
        let result = SessionPanelCap().cap(ids)
        #expect(result.retainedPanelIds == ids)
        #expect(result.omittedCount == 0)
    }

    /// Past the cap the first ids are kept in order and only the rest are counted.
    @Test("Over the cap the ordered prefix is retained and the rest are counted")
    func overTheCapRetainsThePrefixAndCountsTheRest() {
        let ids = (0..<(SessionPanelCap.sessionSnapshotMaxPanels + 3)).map { _ in UUID() }
        let result = SessionPanelCap().cap(ids)
        #expect(result.retainedPanelIds == Array(ids.prefix(SessionPanelCap.sessionSnapshotMaxPanels)))
        #expect(result.omittedCount == 3)
    }

    /// `cap(_:)` must not iterate its input twice.
    @Test("A single-pass sequence is read once")
    func singlePassSequenceIsReadOnce() {
        let ids = (0..<5).map { _ in UUID() }
        var iterator = ids.makeIterator()
        let result = SessionPanelCap(maxPanels: 2).cap(AnySequence { AnyIterator { iterator.next() } })
        #expect(result.retainedPanelIds == Array(ids.prefix(2)))
        #expect(result.omittedCount == 3)
    }

    /// Edge inputs: no ids, a zero cap, and a negative cap clamped to zero.
    @Test("An empty sequence and a zero or negative cap")
    func emptyAndZeroCaps() {
        #expect(SessionPanelCap().cap([UUID]()) == SessionPanelCapResult(retainedPanelIds: [], omittedCount: 0))
        let ids = (0..<2).map { _ in UUID() }
        #expect(SessionPanelCap(maxPanels: 0).cap(ids).omittedCount == 2)
        #expect(SessionPanelCap(maxPanels: -1).maxPanels == 0)
    }
}
