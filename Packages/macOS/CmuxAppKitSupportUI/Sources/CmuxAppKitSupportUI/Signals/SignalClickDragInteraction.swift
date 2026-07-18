/// Signal-owned lifecycle for an AppKit press that can resolve as either a click or a drag.
///
/// AppKit enters its mouse-tracking loop from `mouseDown`. The drag source callback is the
/// threshold-crossing event, while the control action is the completed-click event. Keeping
/// those events in one phase prevents press feedback from masquerading as selection before
/// AppKit has resolved the gesture.
public enum SignalClickDragPhase<Identifier: Equatable, Context: Equatable>: Equatable {
    case idle
    case pressed(id: Identifier, context: Context)
    case dragging(id: Identifier, context: Context)
    case activating(id: Identifier, context: Context)
}

/// Value returned when a press resolves as a click.
public struct SignalClickDragActivation<Identifier: Equatable, Context: Equatable>: Equatable {
    public let id: Identifier
    public let context: Context

    public init(id: Identifier, context: Context) {
        self.id = id
        self.context = context
    }
}

/// Main-actor state machine whose phase is backed by a production ``Signal``.
@MainActor
public final class SignalClickDragInteraction<Identifier: Equatable, Context: Equatable> {
    public typealias Phase = SignalClickDragPhase<Identifier, Context>
    public typealias Activation = SignalClickDragActivation<Identifier, Context>

    private let graph: SignalGraph
    private let phaseSignal: Signal<Phase>

    public init() {
        let graph = SignalGraph()
        self.graph = graph
        self.phaseSignal = graph.createSignal(.idle)
    }

    public var phase: Phase {
        phaseSignal.get()
    }

    public func mouseDown(on id: Identifier, context: Context) {
        phaseSignal.set(.pressed(id: id, context: context))
    }

    /// Resolves a tracked press as a drag after AppKit crosses its drag threshold.
    @discardableResult
    public func dragDidBegin(on id: Identifier) -> Bool {
        guard case let .pressed(pressedId, context) = phaseSignal.get(), pressedId == id else {
            return false
        }
        phaseSignal.set(.dragging(id: id, context: context))
        return true
    }

    /// Resolves a tracked press as a click. A gesture already resolved as a drag cannot activate.
    @discardableResult
    public func mouseUpWithoutDrag(on id: Identifier) -> Activation? {
        guard case let .pressed(pressedId, context) = phaseSignal.get(), pressedId == id else {
            return nil
        }
        phaseSignal.set(.activating(id: id, context: context))
        return Activation(id: id, context: context)
    }

    /// Cancels a press whose tracking loop ended without producing a click or drag callback.
    public func trackingDidEnd() {
        guard case .pressed = phaseSignal.get() else { return }
        phaseSignal.set(.idle)
    }

    public func dragDidEnd() {
        guard case .dragging = phaseSignal.get() else { return }
        phaseSignal.set(.idle)
    }

    /// Ends optimistic activation after the authoritative selection has reconciled.
    public func activationDidReconcile(id: Identifier) {
        guard case let .activating(activeId, _) = phaseSignal.get(), activeId == id else { return }
        phaseSignal.set(.idle)
    }

    /// Observes phase changes synchronously. The context can restore temporary visual state
    /// when the phase changes or the returned effect is disposed.
    public func observePhase(
        _ body: @escaping @MainActor (Phase, SignalEffectContext) -> Void
    ) -> SignalEffect {
        graph.createEffect { [phaseSignal] context in
            body(phaseSignal.get(), context)
        }
    }
}
