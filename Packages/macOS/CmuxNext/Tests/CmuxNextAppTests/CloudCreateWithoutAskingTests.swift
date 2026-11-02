import AppKit
@testable import CmuxNextApp
import CmuxNextCloud
import CmuxNextSettings
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import Foundation
import Testing

/// A Cloud machine an agent or a script asks for is created at once on a paid plan: no
/// "Create a Cloud machine?" card. The Free plan, a plan with no machines, or a full plan gets one
/// upgrade card instead (never a plain create confirm), and nothing is sent.
@MainActor @Suite(.serialized, .closesItsWindows) struct CloudCreateWithoutAskingTests {
    @MainActor final class Sent {
        var count = 0
        var prompts: [CloudMachineCreateFlow.Prompt] = []
        func send() -> String { count += 1; return "machine" }
    }

    @Test func anAgentsCreateOnAPaidPlanAsksNothing() async throws {
        let sent = Sent()
        let made = try await CloudMachineCreateFlow.legacy(name: "builder", startedByPerson: false, gate: { .allowed },
                                                           confirm: { sent.prompts.append($0); return true },
                                                           create: { sent.send() })
        #expect(made == "machine")
        #expect(sent.count == 1, "the agent's create was not sent")
        #expect(sent.prompts.isEmpty, "a paid-plan agent create still asked: \(sent.prompts)")
    }

    /// An agent's create that the plan gate refuses shows no card and opens no pricing page: the agent gets the refusal as its error.
    @Test func anAgentsCreateOnTheFreePlanShowsNoUpgradeCard() async throws {
        let sent = Sent()
        await #expect(throws: CloudMachineCreateFlow.Failure.upgradeRequired(.freePlan)) {
            try await CloudMachineCreateFlow.legacy(name: nil, startedByPerson: false, gate: { .upgrade(.init(reason: .freePlan)) },
                                                    confirm: { sent.prompts.append($0); return false },
                                                    create: { sent.send() })
        }
        #expect(sent.count == 0, "a Free-plan create went out")
        #expect(sent.prompts.isEmpty, "an agent's refused create showed an upgrade prompt: \(sent.prompts)")
    }

    @Test func theFreePlanGetsTheUpgradeCardAndSendsNothing() async throws {
        let sent = Sent()
        await #expect(throws: CloudMachineCreateFlow.Failure.upgradeRequired(.freePlan)) {
            try await CloudMachineCreateFlow.legacy(name: nil, startedByPerson: true, gate: { .upgrade(.init(reason: .freePlan)) },
                                                    confirm: { sent.prompts.append($0); return false },
                                                    create: { sent.send() })
        }
        #expect(sent.count == 0, "a Free-plan create went out")
        #expect(sent.prompts == [.upgrade(.init(reason: .freePlan))], "no single upgrade prompt: \(sent.prompts)")
    }

    @Test func aServerPlanRefusalBecomesTheUpgradeCard() async throws {
        let sent = Sent()
        await #expect(throws: CloudMachineCreateFlow.Failure.upgradeRequired(.server)) {
            try await CloudMachineCreateFlow.legacy(name: nil, startedByPerson: false, gate: { .allowed },
                                                    confirm: { sent.prompts.append($0); return false },
                                                    create: { () async throws -> String in throw CloudAPIError.http(status: 402, code: "vm_active_limit_exceeded", message: "full") })
        }
        #expect(sent.prompts == [.upgrade(.init(reason: .server))])
    }

    @Test func gateReadsThePlanLimits() {
        #expect(CloudMachineCreateFlow.gate(nil) == .allowed, "unknown limits must leave the server to decide")
        #expect(CloudMachineCreateFlow.gate(.init(maxActiveVms: 5, activeVmCount: 1, planId: "pro")) == .allowed)
        #expect(CloudMachineCreateFlow.gate(.init(maxActiveVms: 0, activeVmCount: 0, planId: "free")) == .upgrade(.init(reason: .freePlan)))
        #expect(CloudMachineCreateFlow.gate(.init(maxActiveVms: nil, activeVmCount: 0, planId: "free")) == .upgrade(.init(reason: .freePlan)))
        #expect(CloudMachineCreateFlow.gate(.init(maxActiveVms: 2, activeVmCount: 2, planId: "go")) == .upgrade(.init(reason: .atLimit(2))))
    }

    /// With no window to ask in, a refused create that no person started must not open pricing by itself.
    @Test func aRefusedAgentCreateWithNoWindowOpensNoPricingPage() async throws {
        var opened: [URL] = []
        let answer = await CloudPresenter.confirmCreate(.upgrade(.init(reason: .freePlan)), in: nil, asks: nil, openPricing: { opened.append($0) })
        #expect(opened.isEmpty, "a pricing page opened by itself: \(opened)")
        #expect(answer == false)
    }

    @Test func theUpgradeCardNamesThePlanAndPriceAndUpgradeOpensPricing() async throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let services = AppServices(environment: AppEnvironment.current([:]))
        let asks = services.machineAsks
        var opened: [URL] = []
        let answer = Task { @MainActor in
            await CloudPresenter.confirmCreate(.upgrade(.init(reason: .freePlan)), in: window, asks: asks, openPricing: { opened.append($0) })
        }
        let deadline = ContinuousClock.now + .seconds(5)
        while asks.card == nil, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) } // test-only, bounded
        let card = try #require(asks.card, "no upgrade card")
        #expect(card.title == CloudStrings.upgradeTitle)
        #expect(card.detail?.contains("$10") == true, "the card names no price: \(card.detail ?? "nil")")
        #expect(card.actions.map(\.title) == [CloudStrings.upgradeButton, CloudStrings.notNow])
        #expect(!card.actions.map(\.title).contains(CloudStrings.createConfirmButton), "the upgrade card offers a plain Create")
        let upgrade = try #require(card.actions.first { $0.prominent })
        SidebarCardFeed.handle(.noticeAction(card: card.id, action: upgrade.id), services: services)
        #expect(await answer.value)
        #expect(opened == [StaticURL.pricing.url], "Upgrade did not open pricing")
    }
}
