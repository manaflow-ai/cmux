import AppKit
import CmuxNextPages
import CmuxNextWakeups

/// Renders a parked New Tab page at Rust's exact split sizes on its single renderer.
/// Ownership is checked before every resize, after drawing, and when a capture completes.
@MainActor
public final class AgentPaneNewTabPrefetch {
    private var token: UUID?
    private let deadline: DemandTimer

    public init() { deadline = DemandTimer(owner: "NewTabSparePool.prefetch") }
    init(deadline: DemandTimer) { self.deadline = deadline }

    public var active: Bool { token != nil }

    public func cancel() {
        token = nil
        deadline.cancel()
    }

    public func start(
        view: AgentPaneView, parking: PageOffscreenParking, covers: AgentPaneSpareCovers,
        frames: AgentPaneNewTabFrame, appearance: NSAppearance.Name?, generation: UInt64,
        full: CGSize, plan: [CGSize], valid: @escaping @MainActor () -> Bool,
        finished: @escaping @MainActor () -> Void,
        invalidated: @escaping @MainActor () -> Void = {}
    ) {
        guard !active, !plan.isEmpty else { return }
        covers.forget(view)
        start(full: full, plan: plan,
              owns: { view.superview === parking },
              valid: {
                  valid() && frames.generation == generation
                      && view.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == appearance
              },
              resize: { size in
                  view.isHidden = false
                  parking.fit(to: size)
              },
              whenDrawn: { view.whenDrawnAtItsSize($0) },
              capture: { valid, done in
                  view.redraw.rememberFrame(of: view, appearance: appearance, valid: valid, completion: done)
              }, finished: finished, invalidated: invalidated)
    }

    /// The same lifecycle with host effects injected: tests can complete a queued draw/capture
    /// after adoption, a changed appearance, or a deadline without a window-server compositor.
    func start(
        full: CGSize, plan: [CGSize], owns: @escaping @MainActor () -> Bool,
        valid: @escaping @MainActor () -> Bool,
        resize: @escaping @MainActor (CGSize) -> Void,
        whenDrawn: @escaping @MainActor (@escaping @MainActor () -> Void) -> Void,
        capture: @escaping @MainActor (@escaping @MainActor () -> Bool, @escaping @MainActor () -> Void) -> Void,
        finished: @escaping @MainActor () -> Void,
        invalidated: @escaping @MainActor () -> Void
    ) {
        guard !active, !plan.isEmpty else { return }
        let current = UUID()
        token = current
        func invalidate() {
            guard self.token == current else { return }
            self.cancel()
            if owns() { resize(full) }
            invalidated()
        }
        func isCurrent() -> Bool { self.token == current && owns() && valid() }
        deadline.schedule(after: .seconds(3)) { @MainActor in invalidate() }

        func render(_ index: Int) {
            guard self.token == current else { return }
            guard isCurrent() else { return invalidate() }
            guard index < plan.count else {
                self.cancel()
                finished()
                return
            }
            // Register before layout: fitting can draw synchronously at an already cached size.
            whenDrawn {
                guard self.token == current else { return }
                guard isCurrent() else { return invalidate() }
                capture(isCurrent) { render(index + 1) }
            }
            resize(plan[index])
        }
        render(0)
    }
}
