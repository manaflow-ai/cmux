import CmuxNextActions
@testable import CmuxNextControl
import Observation
import Testing

/// Lawrence 2026-10-21: "we need to fix all animation lag as well. for new tabs, making splits, etc." The fleet
/// profile of every pane and tab gesture (anim-perf-terminal.py --sample, aws-m4pro-8) put 13-15 % of the main
/// thread's busy time in `RegistryControlBridge.observeCatalog`: an action's unavailable reason reads app state
/// (the daemon store, the focused pane), so every model change of a split or a new tab rebuilt the whole control
/// catalog (every action's title, shortcut, arguments and surfaces) in the gesture's own turn, several times per
/// gesture. The catalog is what `action.list` and `action.describe` answer; `action.run` re-reads the reason live.
///
/// So a change that only moves an unavailable reason republishes the reasons alone, on a later frame (at most one
/// per frame), never in the turn that changed the state; the rest of an action's entry is built when the registry
/// itself changes.
@MainActor @Suite(.serialized) struct CatalogRepublishCostTests {
    @Observable @MainActor final class Gate {
        var reason: String?
    }

    struct Harness {
        let registry: ActionRegistry
        let bridge: RegistryControlBridge
        let router: ControlRouter
        let frames: ManualFrameSource
        let gate: Gate
    }

    static let gated = ActionID(rawValue: "splitRight")

    static func make() -> Harness {
        let registry = ActionRegistry.standard()
        let gate = Gate()
        registry.bind(gated, unavailable: { gate.reason }, invoke: { _ in })
        let frames = ManualFrameSource()
        let bridge = RegistryControlBridge(registry: registry, frames: frames)
        let router = ControlRouter(identity: testIdentity(), executor: bridge, configuration: .loadTolerant)
        bridge.attach(to: router)
        return Harness(registry: registry, bridge: bridge, router: router, frames: frames, gate: gate)
    }

    static func reason(_ h: Harness) -> String? {
        h.router.catalog.actions.first { $0.id == gated.rawValue }?.unavailableReason
    }

    /// Lets the observation's re-arm task run (it hops to the main actor after the mutation).
    static func settle() async {
        for _ in 0..<4 { await Task.yield() }
    }

    @Test func aReasonChangeIsNotRepublishedInTheTurnThatChangedTheState() async {
        let h = Self.make()
        defer { h.bridge.detach() }
        let built = h.bridge.entryBuilds
        h.gate.reason = "no pane to split"
        await Self.settle()
        // The gesture's turn and its follow-up tasks: no catalog work at all.
        #expect(Self.reason(h) == nil)
        #expect(h.bridge.entryBuilds == built)
        h.frames.fire()
        #expect(Self.reason(h) == "no pane to split")
    }

    @Test func aReasonChangeRebuildsNoActionEntry() async {
        let h = Self.make()
        defer { h.bridge.detach() }
        let built = h.bridge.entryBuilds
        for step in 0..<5 {
            h.gate.reason = step.isMultiple(of: 2) ? "busy" : nil
            await Self.settle()
            h.frames.fire()
        }
        #expect(Self.reason(h) == "busy")
        #expect(h.bridge.entryBuilds == built, "only the reasons are read again, not every action's entry")
    }

    @Test func manyChangesInOneFramePublishOnce() async {
        let h = Self.make()
        defer { h.bridge.detach() }
        for step in 0..<10 {
            h.gate.reason = "step \(step)"
            await Self.settle()
        }
        #expect(h.frames.scheduledCount <= 1)
        h.frames.fire()
        #expect(Self.reason(h) == "step 9")
    }

    @Test func aRegistryChangeStillRebuildsTheEntries() async {
        let h = Self.make()
        defer { h.bridge.detach() }
        let built = h.bridge.entryBuilds
        h.registry.disabledFeatures.insert(.cloud)
        await Self.settle()
        h.frames.fire()
        #expect(h.bridge.entryBuilds > built)
    }
}
