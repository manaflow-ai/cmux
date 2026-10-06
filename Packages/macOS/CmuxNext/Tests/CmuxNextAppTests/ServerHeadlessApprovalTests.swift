import CmuxNextServer
import Foundation
import Testing
@testable import CmuxNextApp

/// `cmux action run server.addServer --arg code=… [--arg name=…] [--arg chief=true]`:
/// the same lookup and approve as the sheet, without a window (scripts and
/// dogfood on a Mac nobody watches).
@MainActor
@Suite struct ServerHeadlessApprovalTests {
    @Test func aCodeIsLookedUpThenApprovedWithTheCandidatesTeam() async {
        let source = MockServerSource(scenario: .unpaired)
        let reject = await ServerHeadlessApproval.run(source: source, code: "7kq4-m2xd", name: nil, runChief: true)
        #expect(reject == nil)
        let candidate = MockServerScenario.candidate
        #expect(source.received.map(\.kind) == [
            .lookupCode("7KQ4M2XD"),
            .approveCode(code: "7KQ4M2XD", team: candidate.teams[0].id, name: candidate.name, placeChief: true),
        ])
    }

    @Test func theChiefFollowsTheServersCapabilityUnlessTold() async {
        let source = MockServerSource(scenario: .unpaired)
        _ = await ServerHeadlessApproval.run(source: source, code: "7KQ4M2XD", name: "build", runChief: nil)
        if case let .approveCode(_, _, name, placeChief) = source.received.last?.kind {
            #expect(name == "build")
            #expect(placeChief == MockServerScenario.candidate.isChiefBrain)
        } else {
            Issue.record("no approve")
        }
    }

    @Test func anUnknownCodeIsRefusedWithoutAnApprove() async {
        let source = MockServerSource(scenario: .unpaired)
        let reject = await ServerHeadlessApproval.run(source: source, code: "AAAA-BBBB", name: nil, runChief: nil)
        #expect(reject != nil)
        #expect(!source.received.contains { if case .approveCode = $0.kind { true } else { false } })
    }
}
