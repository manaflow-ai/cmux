import AppKit
import CmuxNextPages
import CmuxNextWakeups

/// Renders a parked New Tab page at exact split sizes on its one renderer. The App supplies
/// geometry and ownership checks; this target owns the frame scheduling and cancellation.
@MainActor
public final class AgentPaneNewTabPrefetch {
    enum Step: Equatable {
        case render(CGSize)
        case restore
        case finished
    }

    /// Pure lifecycle decision kept beside the renderer so cancellation and stale-context paths
    /// cannot accidentally render another split size or leave the spare fitted there.
    static func step(index: Int, plan: [CGSize], valid: Bool, timedOut: Bool = false) -> Step {
        guard valid, !timedOut else { return .restore }
        guard index < plan.count else { return .finished }
        return .render(plan[index])
    }

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
            guard case let .render(size) = Self.step(index: index, plan: plan, valid: true) else {
                self.cancel()
                finished()
                return
            }
            view.isHidden = false
            view.redraw.when(view) { [weak self, weak view] in
                guard let self, let view, self.token == current, view.superview === parking else { return }
                view.redraw.rememberFrame(of: view, appearance: appearance) { render(index + 1) }
            }
            parking.fit(to: size)
        }
        render(0)
    }
}

/// Owns the attempt identity for a split prefetch.  The app supplies pane
/// geometry and context checks; this type keeps stale attempts from being
/// adopted after a focus, appearance, or generation change.
@MainActor
public final class AgentPaneSplitPrefetch {
    private let renderer = AgentPaneNewTabPrefetch()
    private var lastAttempt: [AnyHashable]?

    public init() {}

    public var active: Bool { renderer.active }

    public func cancel() {
        lastAttempt = nil
        renderer.cancel()
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
        attempt: [AnyHashable],
        valid: @escaping @MainActor () -> Bool,
        finished: @escaping @MainActor () -> Void,
        invalidated: @escaping @MainActor () -> Void = {}
    ) {
        guard !plan.isEmpty, frames.image(size: full, appearance: appearance) != nil,
              lastAttempt != attempt else { return }
        lastAttempt = attempt
        renderer.start(view: view, parking: parking, covers: covers, frames: frames,
                       appearance: appearance, generation: generation, full: full,
                       plan: plan, valid: valid, finished: finished, invalidated: invalidated)
    }
}

/// Frame operations shared by an app's parked New Tab spare and split prefetch.
@MainActor
public final class AgentPaneNewTabSpareFrames {
    private let splitPrefetch = AgentPaneSplitPrefetch()

    public init() {}

    public var active: Bool { splitPrefetch.active }

    public func cancel() { splitPrefetch.cancel() }

    public func fit(
        parking: PageOffscreenParking,
        content: NSView,
        size: CGSize,
        opening: Bool,
        views: [AgentPaneView],
        snapshot: (AgentPaneView) -> Void
    ) {
        guard parking.frame == PageOffscreenParking.frame(in: content.bounds, size: size) else {
            parking.fit(to: size)
            if !opening { views.forEach(snapshot) }
            return
        }
        if !opening { views.filter { $0.redraw.newTabFrameCaptureChanged == nil }.forEach(snapshot) }
    }

    public func snapshot(
        _ view: AgentPaneView,
        parking: PageOffscreenParking,
        covers: AgentPaneSpareCovers,
        parked: @escaping () -> Bool,
        after: @escaping () -> Void
    ) {
        guard !active else { return }
        covers.capture(view, parked: { _ in parked() }) { after() }
    }

    public func prefetch(
        view: AgentPaneView,
        parking: PageOffscreenParking,
        covers: AgentPaneSpareCovers,
        frames: AgentPaneNewTabFrame,
        appearance: NSAppearance.Name?,
        generation: UInt64,
        full: CGSize,
        plan: [CGSize],
        attempt: [AnyHashable],
        valid: @escaping @MainActor () -> Bool,
        finished: @escaping @MainActor () -> Void,
        invalidated: @escaping @MainActor () -> Void = {}
    ) {
        splitPrefetch.start(view: view, parking: parking, covers: covers, frames: frames,
                            appearance: appearance, generation: generation, full: full,
                            plan: plan, attempt: attempt, valid: valid,
                            finished: finished, invalidated: invalidated)
    }
}
