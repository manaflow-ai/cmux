import AppKit
@testable import CmuxNextActions
import Testing

/// A person's run whose handler refuses for a reason that passes by itself (cmux still starting) is held by a
/// ``ActionRegistry/refusalDeferrals`` entry instead of refused; the CLI, MCP and scripts still get the reason.
@MainActor
struct ActionRefusalDeferralTests {
    static let id: ActionID = "openSettings"

    static func registry(held: @escaping @MainActor (ActionID, String) -> Void) -> (ActionRegistry, refused: () -> [String]) {
        let registry = ActionRegistry.standard()
        registry.context = ActionContext(rawValue: .max)
        var refused: [String] = []
        registry.refusalObserver = { reason, _ in refused.append(reason) }
        registry.bind(id, unavailable: { nil }, invoke: { _ in
            registry.refuse("starting")
            registry.refuse("a second refusal in the same run")
        })
        registry.refusalDeferrals.append { id, _, reason in
            guard reason == "starting" else { return false }
            held(id, reason)
            return true
        }
        return (registry, { refused })
    }

    @Test func aPersonsRunIsHeldAndItsRefusalsAreNotShown() {
        var held: [ActionID] = []
        let (registry, refused) = Self.registry { id, _ in held.append(id) }
        let reported = registry.reportingRefusal { registry.perform(Self.id, invocation: ActionInvocation()) }
        #expect(held == [Self.id])
        #expect(refused().isEmpty)
        #expect(reported == nil, "the palette shows nothing for a held run")
        // The next run is its own: it is held again.
        registry.perform(Self.id, invocation: ActionInvocation())
        #expect(held == [Self.id, Self.id])
    }

    /// A nested run that refuses is the one held; the outer run goes on and its own refusals show.
    @Test func aNestedRunIsHeldItselfNotTheRunAroundIt() {
        let registry = ActionRegistry.standard()
        registry.context = ActionContext(rawValue: .max)
        var refused: [String] = [], held: [ActionID] = [], outerFinished = false
        registry.refusalObserver = { reason, _ in refused.append(reason) }
        let inner: ActionID = "cloudOpenDesktop"
        registry.bind(inner, unavailable: { nil }, invoke: { _ in registry.refuse("starting") })
        registry.bind(Self.id, unavailable: { nil }, invoke: { _ in
            registry.perform(inner, invocation: ActionInvocation())
            outerFinished = true
            registry.refuse("the outer run's own refusal")
        })
        registry.refusalDeferrals.append { id, _, reason in
            guard reason == "starting" else { return false }
            held.append(id)
            return true
        }
        registry.perform(Self.id, invocation: ActionInvocation())
        #expect(held == [inner])
        #expect(outerFinished)
        #expect(refused == ["the outer run's own refusal"])
    }

    @Test func automationIsRefusedWithTheReason() {
        var held: [ActionID] = []
        let (registry, _) = Self.registry { id, _ in held.append(id) }
        for origin in [ActionOrigin.cli, .mcp, .script] {
            let refused = registry.capturingRefusal { registry.perform(Self.id, invocation: ActionInvocation(origin: origin)) }
            #expect(refused == "starting")
        }
        #expect(held.isEmpty)
    }

    /// A recovery with no note (the run waits for cmux to finish starting) leaves a context menu row as an
    /// enabled row reads: no reason under it.
    @Test func aRecoveryWithNoNoteShowsNoReason() {
        let registry = ActionRegistry.standard()
        registry.context = ActionContext(rawValue: .max)
        registry.bind(Self.id, unavailable: { "starting" }, invoke: { _ in })
        registry.unavailableRecoveries.append { _, reason in reason == "starting" ? ActionRecovery { _, _ in } : nil }
        let item = NSMenuItem(title: "Settings", action: nil, keyEquivalent: "")
        ActionTargetTitles.decorate(item, id: Self.id, invocation: ActionInvocation(), in: registry)
        #expect(item.toolTip == nil)
    }
}
