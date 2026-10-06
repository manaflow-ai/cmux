@testable import CmuxNextServer
import Foundation
import Testing

@MainActor
struct ServerModelTests {
    private func started(_ scenario: MockServerScenario = .healthyMac, echo: Bool = false) -> (ServerModel, MockServerSource) {
        let source = MockServerSource(scenario: scenario)
        source.echoImmediately = echo
        let model = ServerModel(source: source)
        model.start()
        return (model, source)
    }

    @Test func everyIntentGoesToTheSourceWithAKey() {
        let (model, source) = started()
        model.toggleServer()
        model.showPairingCode()
        model.fix(.sleepEnabled)
        model.openHealth()
        model.revoke(device: "dev_phone")
        #expect(source.received.map(\.kind) == [
            .setEnabled(false), .showPairingCode, .fixCheck(.sleepEnabled), .openHealth, .revokeDevice("dev_phone"),
        ])
        #expect(Set(source.received.map(\.key)).count == 5, "each intent has its own idempotency key")
        #expect(model.pending.map(\.key) == source.received.map(\.key))
    }

    @Test func intentsNeverChangeTheSnapshotBeforeTheOwnerEchoes() {
        let (model, source) = started()
        model.toggleServer()
        model.revoke(device: "dev_phone")
        #expect(model.snapshot?.enabled == true)
        #expect(model.snapshot?.devices.contains { $0.id == "dev_phone" } == true)
        source.deliverHeld()
        #expect(model.pending.isEmpty)
        #expect(model.snapshot?.enabled == false)
        #expect(model.overall == .off)
        #expect(model.snapshot?.devices.contains { $0.id == "dev_phone" } == false)
    }

    @Test func fixResolvesOnlyThroughTheOwner() {
        let (model, source) = started(.batteryLowDisk)
        #expect(model.openAlerts.map(\.check).contains(.diskLow))
        model.fix(.diskLow)
        #expect(model.isFixing(.diskLow))
        #expect(model.openAlerts.map(\.check).contains(.diskLow))
        source.deliverHeld()
        #expect(!model.isFixing(.diskLow))
        #expect(!model.openAlerts.map(\.check).contains(.diskLow))
        #expect(model.timeline.contains { $0.check == .diskLow && $0.resolvedAt != nil })
    }

    @Test func nothingIsSentWhileTheServerIsUnreachable() {
        let (model, source) = started()
        source.disconnect("stopped")
        #expect(model.send(.showPairingCode) == false)
        #expect(source.received.isEmpty)
        #expect(model.overall == .unavailable)
        #expect(model.lastReject != nil)
    }

    @Test func approverLooksUpACompleteCodeThenApproves() {
        let (model, source) = started(.unpaired)
        model.setApprovalCode("7kq4-m2x")
        #expect(source.received.isEmpty, "an incomplete code is not looked up")
        model.setApprovalCode("7kq4-m2xd")
        #expect(model.approval.code == "7KQ4-M2XD")
        #expect(source.received.last?.kind == .lookupCode("7KQ4M2XD"))
        source.deliverHeld()
        #expect(model.candidate?.name == "build-01")
        #expect(model.approval.team == "team_personal")
        #expect(model.approval.name == "build-01")
        model.approval.team = "team_manaflow"
        #expect(model.canApprove)
        model.approve()
        #expect(source.received.last?.kind == .approveCode(code: "7KQ4M2XD", team: "team_manaflow", name: "build-01"))
        #expect(!model.canApprove, "no second approve while one is in flight")
        source.deliverHeld()
        #expect(model.lastApproved == "build-01")
        #expect(model.candidate == nil)
        #expect(model.approval == ServerApprovalDraft())
    }

    @Test func unknownCodeIsRefusedByTheOwner() {
        let (model, source) = started(.unpaired)
        model.setApprovalCode("AAAA-BBBB")
        source.deliverHeld()
        #expect(model.candidate == nil)
        #expect(model.lastReject != nil)
        #expect(!model.canApprove)
    }

    @Test func overallFollowsPairingAndSeverity() {
        #expect(started(.healthyMac).0.overall == .serving, "an info alert does not need attention")
        #expect(started(.batteryLowDisk).0.overall == .attention(.critical))
        #expect(started(.unpaired).0.overall == .unpaired)
        #expect(started(.linuxHeadless).0.overall == .attention(.critical))
    }

    @Test func showPairingCodeLeavesAPairedServerAlone() {
        let (model, source) = started(.healthyMac)
        model.showPairingCode()
        source.deliverHeld()
        #expect(model.snapshot?.pairing.isPaired == true)
    }
}
