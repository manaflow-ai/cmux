import AppKit
import ObjectiveC

@MainActor
enum WindowBackdropApplyScheduler {
    typealias ApplyHandler = (WindowBackdropPlan, NSWindow) -> WindowBackdropApplicationResult
    typealias Completion = (WindowBackdropApplicationResult) -> Void
    typealias Enqueue = (@escaping () -> Void) -> Void

    @discardableResult
    static func schedule(
        plan: WindowBackdropPlan,
        to window: NSWindow,
        enqueue: Enqueue? = nil,
        apply: @escaping ApplyHandler = WindowBackdropController.apply(plan:to:),
        completion: Completion? = nil
    ) -> Bool {
        let existingState = state(for: window)
        let mutationID = plan.appKitMutationID
        guard existingState.lastAppliedMutationID != mutationID || existingState.pendingMutationID != nil else {
            return false
        }

        existingState.generation += 1
        let generation = existingState.generation
        existingState.pendingMutationID = mutationID
        existingState.pendingCompletion = completion

        if let enqueue {
            enqueue { [weak window] in
                MainActor.assumeIsolated {
                    applyPending(
                        plan: plan,
                        to: window,
                        mutationID: mutationID,
                        generation: generation,
                        apply: apply
                    )
                }
            }
        } else {
            DispatchQueue.main.async { [weak window] in
                MainActor.assumeIsolated {
                    applyPending(
                        plan: plan,
                        to: window,
                        mutationID: mutationID,
                        generation: generation,
                        apply: apply
                    )
                }
            }
        }

        return true
    }

    private static func applyPending(
        plan: WindowBackdropPlan,
        to window: NSWindow?,
        mutationID: String,
        generation: Int,
        apply: ApplyHandler
    ) {
        guard let window else { return }
        let currentState = state(for: window)
        guard currentState.generation == generation,
              currentState.pendingMutationID == mutationID else {
            return
        }

        let result = apply(plan, window)
        currentState.lastAppliedMutationID = mutationID
        currentState.pendingMutationID = nil
        let completion = currentState.pendingCompletion
        currentState.pendingCompletion = nil
        completion?(result)
    }

    private static func state(for window: NSWindow) -> State {
        if let state = objc_getAssociatedObject(window, &stateKey) as? State {
            return state
        }
        let state = State()
        objc_setAssociatedObject(window, &stateKey, state, .OBJC_ASSOCIATION_RETAIN)
        return state
    }

    private final class State: NSObject {
        var generation = 0
        var lastAppliedMutationID: String?
        var pendingMutationID: String?
        var pendingCompletion: Completion?
    }
}

private var stateKey: UInt8 = 0
