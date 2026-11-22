import CmuxNextSettings
import Testing
@testable import CmuxNextAgentPane

/// The Release page-source counts (``AgentPageSourceCounts``): each chat-page make counted once, the cold reasons
/// (``AgentPaneSpareAdoption/coldReason(relaunchWake:chiefKeeps:)``) in the order ``AgentPaneSpareAdoption/adopted(chiefKeeps:)`` tests them.
@Suite
struct AgentPageSourceCountsTests {
    @Test func countsEachOutcomeOnce() {
        var counts = AgentPageSourceCounts()
        counts.record(.spareAdopted)
        counts.record(.spareAdopted)
        counts.record(.spareEmpty)
        counts.record(.spareUnready)
        counts.record(.spareRefused(.noHandshake))
        counts.record(.kept)
        counts.record(.cold(.wakeState))
        #expect(counts.spareAdopted == 2)
        #expect(counts.spareEmpty == 1)
        #expect(counts.spareUnready == 1)
        #expect(counts.spareRefused == 1)
        #expect(counts.kept == 1)
        #expect(counts.cold == 1)
        #expect(counts.refusedWhy == ["no_handshake": 1])
        #expect(counts.coldWhy == ["wake_state": 1])
    }

    @Test func reasonsKeepTheirOwnKeys() {
        var counts = AgentPageSourceCounts()
        counts.record(.spareRefused(.touched(by: "someone")))
        counts.record(.spareRefused(.touched(by: "else")))
        counts.record(.cold(.notThisMac))
        counts.record(.cold(.spareNotTaken))
        #expect(counts.refusedWhy == ["touched": 2])
        #expect(counts.coldWhy == ["not_this_mac": 1, "spare_not_taken": 1])
    }

    /// Constant memory: a reason map past ``AgentPageSourceCounts/maxReasons`` keys counts its new keys as "other".
    @Test func reasonMapIsBounded() {
        var map: [String: Int] = [:]
        for index in 0..<40 {
            AgentPageSourceCounts.bump(&map, "reason_\(index)")
        }
        #expect(map.count == AgentPageSourceCounts.maxReasons + 1)
        #expect(map[AgentPageSourceCounts.otherReason] == 40 - AgentPageSourceCounts.maxReasons)
        AgentPageSourceCounts.bump(&map, "reason_0")
        #expect(map["reason_0"] == 2)
    }

    @Test func coldReasonFollowsAdoptionOrder() {
        func reason(thisMac: Bool = true, session: String? = "s-1", newTabPage: Bool = false, seeded: Bool = false,
                    wake: Bool = false, relaunch: Bool = false, chiefKeeps: Bool = false) -> AgentPageColdReason {
            AgentPaneSpareAdoption(thisMac: thisMac, session: session, newTabPage: newTabPage, seeded: seeded, wake: wake)
                .coldReason(relaunchWake: relaunch, chiefKeeps: { _ in chiefKeeps })
        }
        #expect(reason(thisMac: false) == .notThisMac)
        #expect(reason(newTabPage: true) == .newTabPage)
        #expect(reason(seeded: true) == .seeded)
        #expect(reason(wake: true) == .wakeState)
        #expect(reason(wake: true, relaunch: true) == .relaunchWake)
        #expect(reason(chiefKeeps: true) == .chiefKeeps)
        #expect(reason() == .spareNotTaken)
        // The reasons agree with `adopted`: an eligible open is adopted, every other one is not.
        #expect(AgentPaneSpareAdoption(thisMac: true, session: "s-1", newTabPage: false, seeded: false, wake: false).adopted(chiefKeeps: { _ in false }) == "s-1")
        #expect(AgentPaneSpareAdoption(thisMac: true, session: "s-1", newTabPage: false, seeded: false, wake: true).adopted(chiefKeeps: { _ in false }) == nil)
    }

    @Test func refusalReasonsKeepTheTraceText() {
        #expect(AgentPaneSpareRefusalReason.hasSession.text == "has a session")
        #expect(AgentPaneSpareRefusalReason.noNewTabPage.text == "no new tab page")
        #expect(AgentPaneSpareRefusalReason.noHandshake.text == "no handshake")
        #expect(AgentPaneSpareRefusalReason.touched(by: "Leo").text == "touched by Leo")
        #expect(AgentPaneSpareRefusalReason.remoteChat.text == "remote chat")
        #expect(AgentPaneSpareRefusalReason.neverPooled.text == "never pooled")
        #expect(AgentPaneSpareRefusalReason.unknown.text == "?")
        #expect(AgentPaneSpareRefusalReason.touched(by: "x").key == "touched")
    }

    @Test func jsonHasTheReportedShape() {
        var counts = AgentPageSourceCounts()
        counts.record(.spareAdopted)
        counts.record(.cold(.seeded))
        guard case .object(let object) = counts.json else {
            Issue.record("the report is not an object")
            return
        }
        #expect(object["spare_adopted"] == .number(1))
        #expect(object["spare_empty"] == .number(0))
        #expect(object["spare_unready"] == .number(0))
        #expect(object["spare_refused"] == .number(0))
        #expect(object["kept"] == .number(0))
        #expect(object["cold"] == .number(1))
        #expect(object["cold_why"] == .object(["seeded": .number(1)]))
        #expect(object["refused_why"] == .object([:]))
    }

    /// The app's instance: the adoption decision, the spare's outcome and the retirer's kept page count into the
    /// ``AgentPageSources`` they are handed, and `agent.chat.perf page_source` reads it (and zeroes it on `reset`).
    @Test func recordersCountIntoTheInstanceTheyAreHanded() {
        let sources = AgentPageSources()
        let other = AgentPageSources()
        let eligible = AgentPaneSpareAdoption(thisMac: true, session: "s-1", newTabPage: false, seeded: false, wake: false)
        #expect(eligible.adoptedCounting(relaunchWake: false, chiefKeeps: { _ in false }, into: sources) == "s-1")
        #expect(sources.counts == AgentPageSourceCounts(), "an adopted open is counted by the spare's outcome, not as cold")
        let woken = AgentPaneSpareAdoption(thisMac: true, session: "s-2", newTabPage: false, seeded: false, wake: true)
        #expect(woken.adoptedCounting(relaunchWake: true, chiefKeeps: { _ in false }, into: sources) == nil)
        let newChat = AgentPaneSpareAdoption(thisMac: true, session: nil, newTabPage: false, seeded: false, wake: false)
        #expect(newChat.adoptedCounting(relaunchWake: false, chiefKeeps: { _ in false }, into: sources) == nil)
        AgentPaneSpareOutcome.adopted.trace(into: sources)
        AgentPaneSpareOutcome.empty.trace(into: sources)
        AgentPaneSpareOutcome.unready.trace(into: sources)
        AgentPaneSpareOutcome.refused.trace(note: "no handshake", why: .noHandshake, into: sources)
        #expect(sources.counts.cold == 1)
        #expect(sources.counts.coldWhy == ["relaunch_wake": 1])
        #expect(sources.counts.spareAdopted == 1)
        #expect(sources.counts.spareEmpty == 1)
        #expect(sources.counts.spareUnready == 1)
        #expect(sources.counts.refusedWhy == ["no_handshake": 1])
        #expect(other.counts == AgentPageSourceCounts())
        #expect(AgentPageRetirer().takeKept("s-none") == nil)

        let read = AgentChatPerfControl.pageSourceReport(sources, reset: true)
        guard case .object(let report) = read, case .object(let object)? = report["page_source"] else {
            Issue.record("the read has no page_source object")
            return
        }
        #expect(object["spare_adopted"] == .number(1))
        #expect(object["cold"] == .number(1))
        #expect(sources.counts == AgentPageSourceCounts(), "reset zeroes the counts after the read")
        #expect(AgentChatPerfControl.pageSourceReport(nil, reset: false) == .object(["page_source": AgentPageSourceCounts().json]))
    }

    @Test func resetZeroesTheCounts() {
        var counts = AgentPageSourceCounts()
        counts.record(.kept)
        counts.reset()
        #expect(counts == AgentPageSourceCounts())
    }
}
