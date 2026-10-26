@testable import CmuxNextApp
import CmuxNextCloud
import Foundation
import Testing

/// A create cmux Pro would allow fails its creation and offers Pro once, with
/// the server's reason and link; any other refusal only fails the creation.
@MainActor @Suite struct CloudCreationProOfferTests {
    private func run(failingWith error: any Error) async -> (CloudMachineCreation, [CloudMachineCreation.ProRefusal]) {
        var offers: [CloudMachineCreation.ProRefusal] = []
        let flow = CloudCreationFlow(
            creations: CloudCreations(),
            create: { _ in throw error },
            open: { _ in "" },
            show: { _, _ in },
            planRequired: { offers.append($0) }
        )
        let creation = flow.start(in: nil, existing: nil)
        await creation.task?.value
        return (creation, offers)
    }

    @Test func aProRefusalOffersProOnce() async {
        let url = URL(string: "https://cmux.com/pricing")
        let (creation, offers) = await run(failingWith: CloudAPIError.planRequired(message: "Cloud VMs require a cmux Pro subscription.", upgradeURL: url))
        #expect(offers == [CloudMachineCreation.ProRefusal(message: "Cloud VMs require a cmux Pro subscription.", upgradeURL: url)])
        #expect(creation.planRefusal?.plan == "pro")
        guard case .failed = creation.phase else { Issue.record("creation did not fail: \(creation.phase)"); return }
    }

    @Test func theAppServersPlanRequiredOffersPro() async {
        let (_, offers) = await run(failingWith: CloudAppOpFailure(code: CloudAppOpFailure.planRequired, message: "this team has no Cloud plan"))
        #expect(offers == [CloudMachineCreation.ProRefusal(message: nil, upgradeURL: nil)])
    }

    @Test func aMaxRefusalNamesMaxForTheCaller() async {
        let url = URL(string: "https://cmux.com/api/billing/checkout?plan=max")
        let (creation, offers) = await run(failingWith: CloudAPIError.planRequired(message: "This month's compute budget is used up.", upgradeURL: url, plan: "max"))
        let refusal = CloudMachineCreation.ProRefusal(message: "This month's compute budget is used up.", upgradeURL: url, plan: "max")
        #expect(offers == [refusal])
        #expect(creation.planRefusal == refusal)
    }

    @Test func theAppServersPlanRequiredNamesItsPlan() async {
        let (creation, _) = await run(failingWith: CloudAppOpFailure(code: CloudAppOpFailure.planRequired, message: "this size needs Max", details: .object(["plan": .string("max")])))
        #expect(creation.planRefusal?.plan == "max")
    }

    @Test func theFreePlanGateNamesProForTheCaller() async {
        let (creation, offers) = await run(failingWith: CloudMachineCreateFlow.Failure.upgradeRequired(.freePlan))
        let refusal = CloudMachineCreation.ProRefusal(plan: "pro", offered: true)
        #expect(creation.planRefusal == refusal)
        #expect(offers == [refusal], "the flow hands the refusal on; the offer skips it because the gate's card showed")
    }

    @Test func aFullPlanNamesNoPlan() async {
        let (creation, _) = await run(failingWith: CloudMachineCreateFlow.Failure.upgradeRequired(.atLimit(5)))
        #expect(creation.planRefusal == nil)
    }

    @Test func anOrdinaryRefusalOffersNothing() async {
        let (creation, offers) = await run(failingWith: CloudAPIError.http(status: 402, code: "vm_active_limit_exceeded", message: "This plan allows 3 active Cloud VMs at a time."))
        #expect(offers.isEmpty)
        #expect(creation.planRefusal == nil)
        guard case .failed = creation.phase else { Issue.record("creation did not fail: \(creation.phase)"); return }
    }
}
