import CmuxNextCloud
import CmuxNextCloudUI
import CmuxNextDaemon
import CmuxNextDesign
import Foundation
import Testing

/// The card a person's Cloud create at the plan's cap shows when nothing could be paused for it: Pause one (each
/// busy machine), Upgrade, Run on This Mac; a free plan keeps the upgrade card plus Run on This Mac.
@MainActor @Suite struct CloudMachineCapCardTests {
    @Test func everyBusyMachineGetsAPauseButton() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let cap = CloudMachineCap(busy: [.init(machine: "vm_b", name: "paint", lastActiveAt: now.addingTimeInterval(-120)),
                                         .init(machine: "vm_a", name: "docs")])
        let spec = CloudMachineCapCard.spec(cap, now: now)
        #expect(spec.identifier == CloudMachineCapCard.identifier)
        #expect(spec.buttons.map(\.id) == ["cancel", "pause:vm_b", "pause:vm_a", "runHere", "upgrade"])
        #expect(spec.lines.count == 3, "the detail and one line per machine: \(spec.lines)")
        #expect(spec.lines[1].contains("paint") && spec.lines[2] == "docs")
    }

    @Test func aFreePlanOffersUpgradeAndRunHereOnly() {
        let spec = CloudMachineCapCard.spec(CloudMachineCap(freePlan: true), freePlanDetail: "Go is $10 a month.")
        #expect(spec.buttons.map(\.id) == ["cancel", "runHere", "upgrade"])
        #expect(spec.lines == ["Go is $10 a month."])
    }

    /// cmux#56154: at the team's machine-count limit (paused machines count) the card offers Upgrade, never Pause.
    @Test func theTeamsMachineLimitOffersUpgradeAndNoPause() {
        let cap = CloudMachineCap(busy: [.init(machine: "vm_a", name: "docs")], machineLimit: .init(limit: 20, used: 20))
        let spec = CloudMachineCapCard.spec(cap)
        #expect(spec.buttons.map(\.id) == ["cancel", "runHere", "upgrade"])
        #expect(spec.buttons.last?.role == .default, "Upgrade is the default button")
        #expect(spec.title == "Cloud machine limit reached")
        #expect(spec.lines.count == 1 && spec.lines[0].contains("20 of 20"), "\(spec.lines)")
        let unnamed = CloudMachineCapCard.spec(CloudMachineCap(machineLimit: .init()))
        #expect(unnamed.lines.count == 1 && unnamed.lines[0].hasPrefix("Paused machines count"), "\(unnamed.lines)")
    }

    @Test func theTeamsMachineLimitRefusalReadsAsTheLimitCard() {
        let refusal = CloudAppOpFailure(code: "cmux.cloud.vm_limit", message: "at the limit", details: .object(["limit": .number(20), "team_vms": .number(20)]))
        #expect(CloudMachineCap.refusal(refusal) == CloudMachineCap(machineLimit: .init(limit: 20, used: 20)))
        let held = CloudAppOpFailure(code: "cmux.cloud.quota_exceeded", message: "", details: .object(["resource": .string("machines"), "limit": .number(50), "used": .number(50)]))
        #expect(CloudMachineCap.refusal(held)?.machineLimit == .init(limit: 50, used: 50))
    }

    /// cmux#56154: the hourly create limit read as raw text; its card says when it frees up and offers Run on This Mac.
    @Test func theHourlyCreateLimitSaysWhenItFreesUp() {
        let spec = CloudMachineCapCard.spec(CloudMachineCap(busy: [.init(machine: "vm_a", name: "docs")], createRate: .init(limit: 20, retryAfterMs: 600_000)))
        #expect(spec.title == "Hourly machine limit reached")
        #expect(spec.buttons.map(\.id) == ["cancel", "runHere"], "neither Pause nor Upgrade frees the hour")
        #expect(spec.buttons.last?.role == .default)
        #expect(spec.lines.count == 1 && spec.lines[0].contains("10"), "\(spec.lines)")
        let soon = CloudMachineCapCard.spec(CloudMachineCap(createRate: .init()))
        #expect(soon.lines == ["Your team can start another Cloud machine within the hour. Until then, run this on your Mac."])
    }

    @Test func theHourlyCreateLimitRefusalReadsAsItsCard() {
        let details: JSONValue = .object(["retry_after_ms": .number(600_000), "limit": .number(20), "used": .number(20), "window_ms": .number(3_600_000)])
        let refusal = CloudAppOpFailure(code: "cmux.cloud.rate_limited", message: "too many machine creates", details: details)
        #expect(CloudMachineCap.refusal(refusal)?.createRate == .init(limit: 20, retryAfterMs: 600_000))
        let perMinute = CloudAppOpFailure(code: "cmux.cloud.rate_limited", message: "", details: .object(["retry_after_ms": .number(30_000)]))
        #expect(CloudMachineCap.refusal(perMinute) == nil, "the per-minute limit keeps its own words")
    }

    @Test func theAnswerNamesTheChoice() {
        #expect(CloudMachineCapCard.choice(CmuxDialogAnswer(button: "pause:vm_a", role: .normal)) == .pause("vm_a"))
        #expect(CloudMachineCapCard.choice(CmuxDialogAnswer(button: "runHere", role: .normal)) == .runHere)
        #expect(CloudMachineCapCard.choice(CmuxDialogAnswer(button: "upgrade", role: .normal)) == .upgrade)
        #expect(CloudMachineCapCard.choice(CmuxDialogAnswer(button: "cancel", role: .cancel)) == nil)
        #expect(CloudMachineCapCard.choice(CmuxDialogAnswer(button: "", role: .cancel, isDismissal: true)) == nil)
        #expect(CloudMachineCapCard.choice(nil) == nil)
    }

    @Test func atMostThreePauseButtons() {
        let cap = CloudMachineCap(busy: (0..<5).map { .init(machine: "vm_\($0)", name: "m\($0)") })
        #expect(CloudMachineCapCard.spec(cap).buttons.filter { $0.id.hasPrefix("pause:") }.count == CloudMachineCapCard.pauseButtons)
    }
}
