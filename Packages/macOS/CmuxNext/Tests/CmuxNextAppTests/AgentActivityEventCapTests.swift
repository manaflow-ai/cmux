import CmuxNextAgentActivity
import Foundation
import Testing

/// The Activity pane keeps a session's newest events only. Every model change sends the whole
/// projection, every followed session's events included, to the web view as JSON on the main
/// actor, so a long computer-use session that kept every event made each new event cost more.
@MainActor
struct AgentActivityEventCapTests {
    /// `AgentActivityModel.maxEventsPerSession`, written out so this test fails on a model without
    /// the cap by what it keeps, not by a missing name.
    private let cap: UInt64 = 2000

    private func events(_ seqs: ClosedRange<UInt64>) -> [AgentActivityEvent] {
        seqs.map { AgentActivityEvent(seq: $0, time: Date(timeIntervalSince1970: Double($0)), kind: .act, tool: "click") }
    }

    @Test func aSessionKeepsItsNewestEventsOnly() {
        let model = AgentActivityModel(source: AgentActivityMockSource())
        model.apply(.events(session: "s", events(0...(cap + 499))))
        let kept = model.eventsBySession["s"] ?? []
        #expect(AgentActivityModel.maxEventsPerSession == Int(cap))
        #expect(kept.count == Int(cap))
        #expect(kept.first?.seq == 500)
        #expect(kept.last?.seq == cap + 499)
    }

    @Test func batchesThatArriveOneByOneStayCapped() {
        let model = AgentActivityModel(source: AgentActivityMockSource())
        for seq in 0...(cap + 9) { model.apply(.events(session: "s", events(seq...seq))) }
        let kept = model.eventsBySession["s"] ?? []
        #expect(kept.count == Int(cap))
        #expect(kept.first?.seq == 10)
        // A replayed older page adds nothing once newer events are kept.
        model.apply(.events(session: "s", events(0...5)))
        #expect(model.eventsBySession["s"]?.count == Int(cap))
        #expect(model.eventsBySession["s"]?.first?.seq == 10)
    }
}
