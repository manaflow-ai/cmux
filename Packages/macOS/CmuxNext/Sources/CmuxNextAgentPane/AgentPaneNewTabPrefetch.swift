import AppKit
import CmuxNextPages
import CmuxNextWakeups

/// Renders a parked New Tab page at exact split sizes on its one renderer. The App supplies
/// geometry and ownership checks; this target owns the frame scheduling and cancellation.
@MainActor
public final class AgentPaneNewTabPrefetch {
    private var token: UUID?
    private let deadline = DemandTimer(owner: "NewTabSparePool.prefetch")

    public init() {}

    public var active: Bool { token != nil }

    public func cancel() {
        token = nil
        deadline.cancel()
    }

    public func start(
        view: AgentPaneView,
        parking: PageOffscreenParking,
        covers: AgentPaneSpareCovers,
        frames: AgentPaneNewTabFrame,
        appearance: NSAppearance.Name?,
        generation: UInt64,
        full: CGSize,
        plan: [CGSize],
        valid: @escaping @MainActor () -> Bool,
        finished: @escaping @MainActor () -> Void,
        invalidated: @escaping @MainActor () -> Void = {}
    ) {
        guard token == nil, !plan.isEmpty else { return }
        let current = UUID()
        token = current
        deadline.schedule(after: .seconds(3)) { @MainActor [weak self] in
            guard let self, self.token == current else { return }
            self.cancel()
            parking.fit(to: full)
            invalidated()
        }
        covers.forget(view)

        func render(_ index: Int) {
            guard self.token == current, view.superview === parking else { return }
            guard valid(), frames.generation == generation,
                  view.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == appearance else {
                self.cancel()
                invalidated()
                return
            }
            guard index < plan.count else {
                self.cancel()
                finished()
                return
            }
            view.isHidden = false
            view.redraw.when(view) { [weak self, weak view] in
                guard let self, let view, self.token == current, view.superview === parking else { return }
                view.redraw.rememberFrame(of: view, appearance: appearance) { render(index + 1) }
            }
            parking.fit(to: plan[index])
        }
        render(0)
    }
}
