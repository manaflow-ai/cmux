import AppKit

/// Pointer-selection lifecycle for one AppKit sidebar table.
///
/// The table paints the pressed row immediately, but the workspace remains
/// authoritative in TabManager and is activated only after AppKit completes
/// the click. Drag and cancelled-tracking paths leave the lifecycle without
/// waiting for a timer or an unrelated model update to repair the paint.
enum SidebarWorkspaceSelectionInteractionPhase<Identifier: Equatable, Context: Equatable>: Equatable {
    case idle
    case pressed(id: Identifier, context: Context)
    case dragging(id: Identifier, context: Context)
    case activating(id: Identifier, context: Context)
}

struct SidebarWorkspaceSelectionActivation<Identifier: Equatable, Context: Equatable>: Equatable {
    let id: Identifier
    let context: Context
}

struct SidebarWorkspaceSelectionInteraction<Identifier: Equatable, Context: Equatable> {
    typealias Phase = SidebarWorkspaceSelectionInteractionPhase<Identifier, Context>
    typealias Activation = SidebarWorkspaceSelectionActivation<Identifier, Context>

    private(set) var phase: Phase = .idle

    mutating func mouseDown(on id: Identifier, context: Context) {
        phase = .pressed(id: id, context: context)
    }

    mutating func completedClick(on id: Identifier, fallbackContext: Context) -> Activation? {
        let activation: Activation
        switch phase {
        case let .pressed(pressedId, context) where pressedId == id:
            activation = Activation(id: id, context: context)
        case .idle:
            // Accessibility and programmatic table actions can arrive without
            // the table's mouseDown override. They still use this lifecycle.
            activation = Activation(id: id, context: fallbackContext)
        case .pressed, .dragging, .activating:
            return nil
        }
        phase = .activating(id: activation.id, context: activation.context)
        return activation
    }

    mutating func dragDidBegin(on id: Identifier) -> Bool {
        guard case let .pressed(pressedId, context) = phase, pressedId == id else {
            return false
        }
        phase = .dragging(id: id, context: context)
        return true
    }

    mutating func dragDidEnd() {
        guard case .dragging = phase else { return }
        phase = .idle
    }

    /// Returns true when tracking ended without a completed click or drag.
    mutating func trackingDidEnd() -> Bool {
        guard case .pressed = phase else { return false }
        phase = .idle
        return true
    }

    /// Returns true when the authoritative render completed this activation.
    mutating func authoritativeSelectionDidApply(id: Identifier) -> Bool {
        guard case let .activating(activatingId, _) = phase, activatingId == id else {
            return false
        }
        phase = .idle
        return true
    }

    @discardableResult
    mutating func cancel() -> Bool {
        guard phase != .idle else { return false }
        phase = .idle
        return true
    }
}

/// Coalesces rapid plain-click workspace selections to the latest request.
///
/// A selection commit re-renders the container and swaps the terminal
/// content (~tens of ms); without coalescing, a burst of clicks queues one
/// full commit per click and later selections feel progressively slower.
/// Leading edge applies immediately (single clicks keep their latency);
/// clicks landing inside the window replace the pending request and one
/// trailing fire applies only the newest. The row's optimistic press
/// highlight still tracks every click instantly.
///
/// Generic over Clock, and ALL timing derives from that clock, so tests
/// drive the leading edge and the trailing fire deterministically.
/// Production uses ContinuousClock via the convenience initializer.
@MainActor
final class SidebarSelectionCoalescer<C: Clock> where C.Duration == Duration {
    private var pendingApply: (() -> Void)?
    private var trailingTask: Task<Void, Never>?
    private var lastApplied: C.Instant?
    private let window: Duration
    private let clock: C

    init(window: Duration = .milliseconds(100), clock: C) {
        self.window = window
        self.clock = clock
    }

    func request(_ apply: @escaping @MainActor () -> Void) {
        let now = clock.now
        let elapsed = lastApplied.map { $0.duration(to: now) } ?? window
        if trailingTask == nil, elapsed >= window {
            lastApplied = now
            apply()
            return
        }
        pendingApply = apply
        guard trailingTask == nil else { return }
        let delay = max(.zero, window - elapsed)
        // Injected-Clock sleep with cancellation wired to `cancel()`, per the
        // bounded-delay policy (no raw Task.sleep in production paths).
        trailingTask = Task { [weak self, clock] in
            try? await clock.sleep(for: delay)
            guard let self, !Task.isCancelled else { return }
            self.trailingTask = nil
            self.lastApplied = clock.now
            let apply = self.pendingApply
            self.pendingApply = nil
            apply?()
        }
    }

    /// Drops any pending request. Used by gestures that consume the click
    /// without selecting (double-click rename, drag sessions).
    func cancel() {
        trailingTask?.cancel()
        trailingTask = nil
        pendingApply = nil
    }

    /// Applies any pending request immediately, then clears it. Modifier
    /// clicks extend the selection the user SEES — which includes a plain
    /// click still inside the coalescing window — so the pending selection
    /// must land before the modifier mutation. Dropping it made
    /// "click A, cmd-click B" extend the pre-A selection while A's
    /// optimistic highlight snapped away.
    func flushNow() {
        trailingTask?.cancel()
        trailingTask = nil
        let apply = pendingApply
        pendingApply = nil
        if apply != nil { lastApplied = clock.now }
        apply?()
    }
}

extension SidebarSelectionCoalescer where C == ContinuousClock {
    convenience init(window: Duration = .milliseconds(100)) {
        self.init(window: window, clock: ContinuousClock())
    }
}
