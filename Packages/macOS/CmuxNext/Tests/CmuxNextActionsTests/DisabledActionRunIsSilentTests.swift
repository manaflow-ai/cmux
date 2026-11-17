@testable import CmuxNextActions
import Testing

/// A shortcut or menu run of an action that is disabled where it runs does nothing: no toast that
/// sends the person elsewhere (Leo 2026-11-17, about such a toast: "just... stop showijg the toggle
/// on gui"). A caller (the palette, the CLI, MCP) still gets the reason back.
@MainActor
struct DisabledActionRunIsSilentTests {
    static let reason = "This window cannot be minimized."

    private static func registry() -> (ActionRegistry, () -> [(String, Bool)], () -> Int) {
        let registry = ActionRegistry.standard()
        var runs = 0
        registry.bind("minimizeWindow", invoke: { _ in runs += 1 })
        ActionTargetReasons.set("minimizeWindow", in: registry) { _ in Self.reason }
        var refusals: [(String, Bool)] = []
        registry.refusalObserver = { refusals.append(($0, $1)) }
        return (registry, { refusals }, { runs })
    }

    @Test func aTargetReasonRefusesQuietly() {
        let (registry, refusals, runs) = Self.registry()
        #expect(!registry.perform("minimizeWindow", invocation: ActionInvocation(origin: .user)))
        #expect(runs() == 0, "the disabled action ran")
        #expect(refusals().map(\.0) == [Self.reason])
        #expect(refusals().allSatisfy(\.1), "a disabled action's shortcut run asked for the refusal toast")
    }

    @Test func aCallerStillGetsTheReason() {
        let (registry, _, _) = Self.registry()
        let reason = registry.capturingRefusal {
            _ = registry.perform("minimizeWindow", invocation: ActionInvocation(origin: .user))
        }
        #expect(reason == Self.reason)
    }

    /// An action bound unavailable (`bind(_:unavailable:)`) refuses nothing on a run: it is disabled.
    @Test func anUnavailableActionRefusesNothing() {
        let registry = ActionRegistry.standard()
        var ran = false
        registry.bind("minimizeWindow", unavailable: { Self.reason }, invoke: { _ in ran = true })
        var refusals: [String] = []
        registry.refusalObserver = { reason, _ in refusals.append(reason) }
        #expect(!registry.perform("minimizeWindow", invocation: ActionInvocation(origin: .user)))
        #expect(!ran)
        #expect(refusals.isEmpty, "refused: \(refusals)")
        #expect(registry.unavailableReason(for: "minimizeWindow") == Self.reason)
    }
}
