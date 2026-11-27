import AppKit
import CmuxNextDesign
import CmuxNextPages

/// A single parked page's preparation and capture lifecycle. App supplies geometry and ownership
/// as values, so late captures can check the same context without knowing the app's pane objects.
@MainActor
public final class AgentPaneNewTabSpareFrames {
    public struct Context: Equatable {
        public var identity: [AnyHashable]
        public var full: CGSize
        public var splits: [CGSize]

        public init(identity: [AnyHashable], full: CGSize, splits: [CGSize]) {
            self.identity = identity
            self.full = full
            self.splits = splits
        }
    }

    private let renderer = AgentPaneNewTabPrefetch()
    private var lastAttempt: [AnyHashable]?
    private var awaitingPaint: Set<ObjectIdentifier> = []
    public private(set) var deferredPrepares = 0
    public private(set) var preparedFor: [AnyHashable]?

    public init() {}

    public func cancel() { renderer.cancel() }

    public func drop() {
        cancel()
        lastAttempt = nil
        awaitingPaint.removeAll()
    }

    /// Existing parked preparation: a page without its handshake or first paint registers one
    /// callback, then the app schedules the next quiet preparation with its current context.
    public func prepare(
        views: [AgentPaneView], parking: PageOffscreenParking, opening: Bool,
        page: AgentPaneNewTab, identity: [AnyHashable]?,
        retry: @escaping () -> Void, snapshot: @escaping (AgentPaneView) -> Void
    ) {
        guard !opening else { return }
        for view in views where view.superview === parking {
            guard view.model.hasHandshake, view.model.hasPainted else {
                deferredPrepares += 1
                if awaitingPaint.insert(ObjectIdentifier(view)).inserted {
                    view.model.whenPainted { [weak self, weak view] in
                        if let view { self?.awaitingPaint.remove(ObjectIdentifier(view)) }
                        retry()
                    }
                }
                continue
            }
            let prepared = BenchSpans.measure("pool.prepare") { view.prepareNewTab(page) }
            if view === views.first { preparedFor = identity }
            if prepared {
                view.redraw.afterNextFrame { [weak view] in
                    if let view { snapshot(view) }
                }
            }
        }
    }

    public func fit(
        parking: PageOffscreenParking, size: CGSize?, opening: Bool,
        views: [AgentPaneView], snapshot: (AgentPaneView) -> Void
    ) {
        cancel()
        guard let content = parking.superview else { return }
        let size = size ?? content.bounds.size
        if parking.frame != PageOffscreenParking.frame(in: content.bounds, size: size) {
            BenchSpans.measure("pool.fit") { parking.fit(to: size) }
            if !opening { views.forEach(snapshot) }
        } else if !opening {
            views.filter { $0.redraw.newTabFrameCaptureChanged == nil }.forEach(snapshot)
        }
    }

    /// Capture full size first, render Rust's missing split-size plan on this renderer, then
    /// restore full size. Invalid ownership or a changed context stops the attempt at each frame.
    public func snapshot(
        _ view: AgentPaneView, parking: PageOffscreenParking, covers: AgentPaneSpareCovers,
        parked: @escaping (AgentPaneView) -> Bool,
        context: @escaping () -> Context?, invalidated: @escaping () -> Void
    ) {
        guard !renderer.active else { return }
        covers.capture(view, parked: parked) { [weak self, weak view] in
            guard let self, let view, parked(view), let expected = context(), view.model.hasPainted else { return }
            let frames = AgentPaneNewTabFrame.shared
            let appearance = view.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua])
            let generation = frames.generation
            let cached = expected.splits.filter { frames.image(size: $0, appearance: appearance) != nil }
            let plan = AgentPaneNewTabPrefetchPlan.make(parked: expected.full, splits: expected.splits, cached: cached)
            let attempt: [AnyHashable] = [ObjectIdentifier(view), generation, expected.full.width,
                                         expected.full.height, appearance?.rawValue ?? ""] + expected.identity
                + expected.splits.flatMap { [AnyHashable($0.width), AnyHashable($0.height)] }
            guard !plan.isEmpty, lastAttempt != attempt,
                  frames.image(size: expected.full, appearance: appearance) != nil else { return }
            lastAttempt = attempt
            renderer.start(view: view, parking: parking, covers: covers, frames: frames,
                           appearance: appearance, generation: generation, full: expected.full, plan: plan,
                           valid: { [weak view] in view.map(parked) == true && context() == expected },
                           finished: { [weak self, weak view] in
                               guard let self, let view, parked(view) else { return }
                               self.snapshot(view, parking: parking, covers: covers, parked: parked,
                                             context: context, invalidated: invalidated)
                           }, invalidated: invalidated)
        }
    }
}
