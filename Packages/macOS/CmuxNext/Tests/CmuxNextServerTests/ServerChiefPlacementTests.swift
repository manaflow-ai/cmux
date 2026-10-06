@testable import CmuxNextServer
import Foundation
import Testing

/// Server > Add Server… for a Chief brain (brains/DESIGN-cmux-lawrence.md):
/// approving a remote server never needs this Mac to be a server, a server
/// that says it runs a Chief brain offers to run the user's Chief, and the
/// panel shows where the Chief runs.
@MainActor
struct ServerChiefPlacementTests {
    private func started(_ scenario: MockServerScenario = .unpaired) -> (ServerModel, MockServerSource) {
        let source = MockServerSource(scenario: scenario)
        let model = ServerModel(source: source)
        model.start()
        return (model, source)
    }

    @Test func approvingARemoteServerWorksWhileThisMacIsNoServer() {
        let (model, source) = started()
        source.disconnect("not installed")
        model.setApprovalCode("7kq4-m2xd")
        #expect(source.received.last?.kind == .lookupCode("7KQ4M2XD"))
        source.deliverHeld()
        #expect(model.candidate != nil)
        #expect(model.canApprove)
        model.approve()
        if case .approveCode = source.received.last?.kind {} else { Issue.record("approve was not sent") }
        // Controls of this Mac's own server still need it running.
        #expect(model.send(.showPairingCode) == false)
    }

    @Test func aChiefBrainServerRunsTheChiefByDefault() {
        let (model, source) = started()
        model.setApprovalCode("7kq4-m2xd")
        var brain = MockServerScenario.candidate
        brain.isChiefBrain = true
        model.handle(.candidate(brain))
        #expect(model.approval.runChief)
        model.approve()
        #expect(source.received.last?.kind == .approveCode(code: "7KQ4M2XD", team: brain.teams[0].id, name: brain.name, placeChief: true))
    }

    @Test func aPlainServerDoesNotTakeTheChiefUnlessAsked() {
        let (model, source) = started()
        model.setApprovalCode("7kq4-m2xd")
        source.deliverHeld()
        #expect(model.approval.runChief == false)
        model.approve()
        if case let .approveCode(_, _, _, placeChief) = source.received.last?.kind {
            #expect(placeChief == false)
        } else {
            Issue.record("approve was not sent")
        }
    }

    @Test func thePanelShowsWhereTheChiefRuns() {
        let (model, _) = started()
        #expect(model.chief == nil)
        let status = ChiefPlacementStatus(serverName: "cmux-lawrence", chiefName: "Chief", state: .ready, lastReply: Date(timeIntervalSince1970: 10))
        model.handle(.chief(status))
        #expect(model.chief == status)
        model.handle(.chief(nil))
        #expect(model.chief == nil)
    }
}
