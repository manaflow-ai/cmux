import CmuxNextActions
@testable import CmuxNextControl
import Testing

/// state-audit R1: detach then attach must leave one observation chain. The
/// chain armed before the detach must not re-arm after the new attach, or every
/// later registry change publishes twice (and once more per further reattach).
@MainActor
@Suite struct RegistryControlBridgeReattachTests {
    /// Lets the bridge's main-actor republish hops run.
    private func drain() async {
        for _ in 0..<50 { await Task.yield() }
    }

    @Test func reattachKeepsOneObservationChain() async {
        let registry = ActionRegistry.standard()
        let bridge = RegistryControlBridge(registry: registry)
        let router = ControlRouter(identity: testIdentity(), executor: bridge, settings: nil, configuration: .loadTolerant)
        bridge.attach(to: router)
        bridge.detach()
        bridge.attach(to: router)
        await drain()

        for (step, context) in [ActionContext.terminalFocused, .browserFocused, .terminalFocused].enumerated() {
            let before = router.snapshots.current.generation
            registry.context = context
            await drain()
            #expect(router.snapshots.current.generation - before == 1, "change \(step) published once")
            #expect(router.catalog.contextMask == context.rawValue)
        }
    }

    @Test func detachStopsPublishing() async {
        let registry = ActionRegistry.standard()
        let bridge = RegistryControlBridge(registry: registry)
        let router = ControlRouter(identity: testIdentity(), executor: bridge, settings: nil, configuration: .loadTolerant)
        bridge.attach(to: router)
        bridge.detach()
        bridge.attach(to: router)
        bridge.detach()
        await drain()
        let before = router.snapshots.current.generation
        registry.context = .browserFocused
        await drain()
        #expect(router.snapshots.current.generation == before)
    }
}
