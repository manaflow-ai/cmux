import CmuxNextActions
@testable import CmuxNextControl
import Foundation
import Testing

/// cx-bpcj, cx-t7hu: an action's handler runs inside a Swift task, from the control socket and
/// from a gesture alike. The run binds task locals (its view-change permission, the control
/// socket's command scope). Bound where no task is current (a run-loop block, an AppKit event),
/// they live in the thread's fallback storage; an isolated deinit run inline there makes the
/// Swift 6.2 runtime `free()` a stop-lookup marker its global task allocator made, which
/// corrupts the heap and trapped the app under CEF (home.show, tab.search, tab.setIcon).
@MainActor
@Suite struct ActionRunInsideTaskTests {
    /// What the handler saw.
    @MainActor
    final class Seen {
        var ran = false
        var insideTask = false
    }

    /// An object whose deinit hops to the main actor, released by the handler as a view or a
    /// palette page is when an action replaces it. The corruption that release causes outside a
    /// task does not trap reliably under the system allocator, so the tests check the condition
    /// (the handler runs inside a task), not the trap.
    @MainActor
    final class IsolatedRelease {
        isolated deinit {}
    }

    func bind(_ registry: ActionRegistry, _ seen: Seen) {
        registry.bind("splitRight", invoke: { _ in
            seen.ran = true
            seen.insideTask = withUnsafeCurrentTask { $0 != nil }
            _ = IsolatedRelease()
        })
    }

    @Test func aControlSocketRunHandlesItsActionInsideATask() async {
        let registry = ActionRegistry.standard()
        let seen = Seen()
        bind(registry, seen)
        let bridge = RegistryControlBridge(registry: registry)
        let router = ControlRouter(identity: testIdentity(), executor: bridge, settings: nil, configuration: .loadTolerant)
        router.updateCatalog(RegistryControlBridge.catalog(from: registry))
        let result = await router.handle(ControlRequest(id: "1", method: "action.run", params: ["action": .string("splitRight")]))
        #expect((try? result.get()) != nil, "\(result)")
        #expect(seen.ran)
        #expect(seen.insideTask)
    }

    /// A key equivalent or menu item performs from an AppKit event, where no task is current;
    /// a main-queue block stands in for it.
    @Test func aGestureRunHandlesItsActionInsideATask() async {
        let registry = ActionRegistry.standard()
        let seen = Seen()
        bind(registry, seen)
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    #expect(withUnsafeCurrentTask { $0 == nil }, "the harness performs where no task is current")
                    registry.perform("splitRight")
                }
                done.resume()
            }
        }
        #expect(seen.ran)
        #expect(seen.insideTask)
    }
}
