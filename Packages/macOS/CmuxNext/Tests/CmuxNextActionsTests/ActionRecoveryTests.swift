import AppKit
@testable import CmuxNextActions
import Testing

/// HQ #4884: an action disabled by a reason a recovery answers (Sign In for a signed-out Cloud
/// action) runs that recovery for a person's own gesture, from the palette, a menu or a key,
/// and is refused as before for the CLI, MCP, scripts and pages.
@MainActor
struct ActionRecoveryTests {
    static let id: ActionID = "cloudOpenDesktop"

    /// A registry with `id` signed out, a recovery for "sign in", and the runs it recorded.
    static func signedOut(reason: String = "sign in") -> (ActionRegistry, ran: () -> Int, recovered: () -> [ActionID]) {
        let registry = ActionRegistry.standard()
        registry.context = ActionContext(rawValue: .max)
        var ran = 0, recovered: [ActionID] = []
        registry.bind(id, unavailable: { reason }, invoke: { _ in ran += 1 })
        registry.unavailableRecoveries.append { _, reason in
            reason == "sign in" ? ActionRecovery(note: "signs in first") { id, _ in recovered.append(id) } : nil
        }
        return (registry, { ran }, { recovered })
    }

    @Test func aPersonsRunTakesTheRecoveryInsteadOfTheHandler() {
        let (registry, ran, recovered) = Self.signedOut()
        #expect(registry.perform(Self.id, invocation: ActionInvocation()))
        #expect(recovered() == [Self.id])
        #expect(ran() == 0)
        #expect(registry.personRecovery(for: Self.id)?.note == "signs in first")
    }

    @Test func automationIsRefusedWithTheReason() {
        let (registry, ran, recovered) = Self.signedOut()
        for origin in [ActionOrigin.cli, .mcp, .script, .page, .remote] {
            #expect(!registry.perform(Self.id, invocation: ActionInvocation(origin: origin)))
            #expect(registry.personRecovery(for: Self.id, ActionInvocation(origin: origin)) == nil)
        }
        // A person's invocation nested in a CLI run is still the CLI's.
        ActionRunScope.$current.withValue(ActionRunScope(origin: .cli, allowsViewChange: false)) {
            #expect(!registry.perform(Self.id, invocation: ActionInvocation()))
        }
        #expect(recovered().isEmpty)
        #expect(ran() == 0)
        #expect(registry.unavailableReason(for: Self.id) == "sign in")
    }

    @Test func aReasonNoRecoveryAnswersStaysDisabled() {
        let (registry, _, recovered) = Self.signedOut(reason: "no backend")
        #expect(!registry.perform(Self.id, invocation: ActionInvocation()))
        #expect(registry.personRecovery(for: Self.id) == nil)
        #expect(recovered().isEmpty)
    }

    @Test func theMenuRowStaysClickableOnlyWhileARecoveryAnswers() throws {
        let (registry, _, _) = Self.signedOut()
        let item = try #require(registry.makeMenuItem(for: Self.id))
        #expect(registry.menuTarget.validateMenuItem(item))
        let (other, _, _) = Self.signedOut(reason: "no backend")
        let disabled = try #require(other.makeMenuItem(for: Self.id))
        #expect(!other.menuTarget.validateMenuItem(disabled))
    }

    /// A context menu row shows the recovery's note, never the stale reason.
    @Test func aContextMenuRowShowsTheRecoveryNote() {
        let (registry, _, _) = Self.signedOut()
        let item = NSMenuItem(title: "Open Desktop", action: nil, keyEquivalent: "")
        ActionTargetTitles.decorate(item, id: Self.id, invocation: ActionInvocation(), in: registry)
        #expect(item.toolTip == "signs in first")
        let (other, _, _) = Self.signedOut(reason: "no backend")
        let disabled = NSMenuItem(title: "Open Desktop", action: nil, keyEquivalent: "")
        ActionTargetTitles.decorate(disabled, id: Self.id, invocation: ActionInvocation(), in: other)
        #expect(disabled.toolTip == "no backend")
    }

    /// A key equivalent the key router gave elsewhere still loses, recovery or not.
    @Test func theMenuKeyEquivalentGateStillHolds() throws {
        let (registry, _, _) = Self.signedOut()
        let item = try #require(registry.makeMenuItem(for: Self.id))
        item.keyEquivalent = "y"
        registry.isDispatchingKeyDown = { true }
        registry.menuKeyEquivalentGate = { _ in false }
        #expect(!registry.menuTarget.validateMenuItem(item))
        registry.menuKeyEquivalentGate = { _ in true }
        #expect(registry.menuTarget.validateMenuItem(item))
    }

    /// A shortcut resolves to a recoverable action, so the key reaches the recovery.
    @Test func aShortcutResolvesToARecoverableAction() {
        let (registry, _, recovered) = Self.signedOut()
        let bindings = RegistryKeyBindings(registry)
        #expect(bindings.canPerform(Self.id, in: ActionContext(rawValue: .max)))
        let (other, _, _) = Self.signedOut(reason: "no backend")
        #expect(!RegistryKeyBindings(other).canPerform(Self.id, in: ActionContext(rawValue: .max)))
        var invocation = ActionInvocation()
        invocation.keyContext = ActionContext(rawValue: .max)
        #expect(registry.perform(Self.id, invocation: invocation))
        #expect(recovered() == [Self.id])
    }
}
