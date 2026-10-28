@testable import CmuxNextActions
import Testing

/// The action pipeline (``ActionEffect``): the handler's change is in place when `perform`
/// returns, the registry (not the handler) starts the remote half after that, a capturing caller
/// awaits it, a failure rolls back and is shown once, and a waiting effect is counted.
@MainActor
@Suite struct ActionEffectTests {
    private static let catalog = [ActionDescriptor(id: "test.rename", title: "Rename", category: .other)]

    private final class World {
        var shown = "old"
        var sent = 0
        var rolledBack: [String] = []
        var notices: [String] = []
        /// Called after each notice (a test waits for it on a continuation).
        var onNotice: (() -> Void)?
    }

    private static func registry(_ world: World, failing: Bool, wait: Bool = false) -> ActionRegistry {
        let registry = ActionRegistry(catalog: catalog)
        registry.remoteFailureObserver = { _, notice in
            world.notices.append(notice)
            world.onNotice?()
        }
        registry.bindEffect("test.rename", effect: { _ in
            let previous = world.shown
            world.shown = "new"
            let send: @MainActor () async -> ActionWorkFailure? = {
                world.sent += 1
                return failing ? "refused by the daemon" : nil
            }
            if wait { return .waiting(.daemonEcho, send) }
            return .applied(ActionConfirmation(send: send, rollback: { _ in
                world.shown = previous
                world.rolledBack.append(previous)
            }))
        })
        return registry
    }

    @Test func theChangeIsInPlaceBeforeAnyRemoteWorkRuns() async {
        let world = World()
        let registry = Self.registry(world, failing: false)
        let work = registry.capturingWork { registry.perform("test.rename") }
        #expect(world.shown == "new")
        #expect(world.sent == 0, "the remote half ran inside the input's turn")
        #expect(work.count == 1)
        for task in work { #expect(await task.value == nil) }
        #expect(world.sent == 1)
        #expect(world.notices.isEmpty)
        #expect(registry.effectBoundCount == 1)
    }

    /// A failure the person did not wait on (a key or menu run) rolls back and shows the notice once.
    @Test func aFailureRollsBackAndIsShownOnce() async {
        let world = World()
        let registry = Self.registry(world, failing: true)
        // Not capturing: a keyboard run. The notice is the signal that the remote half ended.
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            world.onNotice = { done.resume() }
            registry.perform("test.rename")
            #expect(world.shown == "new")
        }
        #expect(world.shown == "old")
        #expect(world.rolledBack == ["old"])
        #expect(world.notices.count == 1)
        #expect(world.notices.first?.contains("refused by the daemon") == true)
    }

    /// A capturing caller (the control socket) gets the failure itself: rolled back, no notice.
    @Test func aCapturingCallerGetsTheFailureAndNoNotice() async {
        let world = World()
        let registry = Self.registry(world, failing: true)
        let work = registry.capturingWork { registry.perform("test.rename") }
        var failures: [ActionWorkFailure?] = []
        for task in work { failures.append(await task.value) }
        #expect(failures.map { $0?.message } == ["refused by the daemon"])
        #expect(world.shown == "old")
        #expect(world.notices.isEmpty)
    }

    @Test func aWaitingEffectIsCountedPerActionAndReason() async {
        let world = World()
        let registry = Self.registry(world, failing: false, wait: true)
        for task in registry.capturingWork({ registry.perform("test.rename"); registry.perform("test.rename") }) { _ = await task.value }
        #expect(registry.waitingRuns["test.rename"]?[.daemonEcho] == 2)
    }

    @Test func aRefusedEffectRefuses() {
        let registry = ActionRegistry(catalog: Self.catalog)
        registry.bindEffect("test.rename", effect: { _ in .refused("no name") })
        let reason = registry.capturingRefusal { registry.perform("test.rename") }
        #expect(reason == "no name")
    }

    /// A legacy rebind of an effect-bound id is counted as legacy again.
    @Test func aLegacyRebindIsNotCountedAsAnEffect() {
        let registry = ActionRegistry(catalog: Self.catalog)
        registry.bindEffect("test.rename", effect: { _ in .done })
        registry.bind("test.rename", invoke: { _ in })
        #expect(registry.effectBoundCount == 0)
        #expect(registry.legacyBoundCount == 1)
    }
}
