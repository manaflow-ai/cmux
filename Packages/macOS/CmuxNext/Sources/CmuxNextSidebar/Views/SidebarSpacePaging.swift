import AppKit
import CmuxNextDesign
import QuartzCore

/// R99: the sidebar's spaces are pages side by side in dot order. A
/// two-finger horizontal scroll moves the workspace list 1:1 with the
/// fingers with the real rows of the space beside it (`SidebarModel
/// .spaceSections`), rubber-bands at the ends and snaps by distance or
/// velocity (`SpacePager`). A switch by dot, key or a new space slides the
/// old page out and the new one in from the side of its dot; with reduced
/// motion the pages cross-fade. Pages move by layer translation only (no
/// layout, no reload during the gesture).
@MainActor final class SidebarSpacePaging {
    private unowned let host: SidebarView
    private var pager: SpacePager?
    private var profiles: [ProfileKey] = []
    private(set) var neighbor: (index: Int, view: NSView, list: SidebarListView)?
    private var samples: [(time: TimeInterval, dx: CGFloat)] = []
    /// The space a release switched to, until the model shows it.
    private(set) var pendingTarget: ProfileKey?
    private var snapshot: NSView?
    var snapshotView: NSView? { snapshot }

    init(host: SidebarView) { self.host = host }

    private var page: NSView { host.scrollView }
    private var width: CGFloat { max(1, page.frame.width) }

    // MARK: Gesture

    /// One horizontal scroll event over the list (`SidebarScrollView`).
    func scroll(_ phase: ProfileSwipeTracker.Phase, deltaX: CGFloat, time: TimeInterval) {
        switch phase {
        case .began:
            start()
            move(deltaX, time)
        case .changed:
            if pager == nil { start() }
            move(deltaX, time)
        case .ended:
            release()
        case .momentum:
            break
        }
    }

    private func start() {
        finishSlide()
        profiles = host.model.profiles.map(\.id)
        guard profiles.count > 1, pendingTarget == nil, let active = host.model.activeProfileID,
              let index = profiles.firstIndex(of: active) else { return }
        pager = SpacePager(index: index, count: profiles.count)
        samples = []
        host.clipsToBounds = true
        page.wantsLayer = true
    }

    private func move(_ dx: CGFloat, _ time: TimeInterval) {
        guard var pager else { return }
        pager.drag(by: dx, width: width)
        self.pager = pager
        samples.append((time, dx))
        samples.removeAll { time - $0.time > 0.1 }
        showNeighbor(pager.neighbor)
        place(offset: pager.offset, animated: nil)
    }

    private func release() {
        guard let pager else { return }
        let span = (samples.last?.time ?? 0) - (samples.first?.time ?? 0)
        let velocity = span > 0 ? samples.dropFirst().reduce(0) { $0 + $1.dx } / span : 0
        let target = pager.target(velocity: velocity, width: width)
        self.pager = nil
        let goes = target != pager.index
        let end: CGFloat = goes ? (target > pager.index ? 1 : -1) : 0
        if goes { pendingTarget = profiles[target] }
        place(offset: end, animated: .settle) { [weak self] in
            guard let self else { return }
            if goes, let target = self.pendingTarget {
                self.host.model.send(.switchProfile(target))
            } else {
                self.endPaging()
            }
        }
    }

    /// The model shows the space a release switched to: the real list takes
    /// the page's place at once (no reload animation, no second slide).
    func modelDidSwitch(to profile: ProfileKey?) -> Bool {
        guard let pendingTarget, pendingTarget == profile else { return false }
        endPaging()
        return true
    }

    private func endPaging() {
        pendingTarget = nil
        neighbor?.view.removeFromSuperview()
        neighbor = nil
        translate(page, 0, animated: nil)
        host.clipsToBounds = false
    }

    private func showNeighbor(_ index: Int?) {
        guard neighbor?.index != index else { return }
        neighbor?.view.removeFromSuperview()
        neighbor = nil
        guard let index else { return }
        let container = makePage(host.model.spaceSections?(profiles[index]) ?? [])
        // The list sits in the edge fade view: pages are its siblings there.
        (page.superview ?? host).addSubview(container, positioned: .above, relativeTo: page)
        guard let list = container.list else { return }
        list.reload(animated: false)
        neighbor = (index, container, list)
    }

    private func place(offset: CGFloat, animated spring: MotionSpring?, completion: (() -> Void)? = nil) {
        CATransaction.begin()
        CATransaction.setCompletionBlock { MainActor.assumeIsolated { completion?() } }
        translate(page, -offset * width, animated: spring)
        if let neighbor, let current = pager?.index ?? profiles.firstIndex(where: { $0 == host.model.activeProfileID }) {
            let side: CGFloat = neighbor.index > current ? 1 : -1
            translate(neighbor.view, (side - offset) * width, animated: spring)
        }
        CATransaction.commit()
    }

    private static let slideKey = "spacePaging.translation"

    /// Moves a page to `x`, with `spring` from its current on-screen offset
    /// (or `from`). The spring holds its end value until the page moves
    /// again or goes away (cx-5k3r, "spaces animation is jank"): AppKit may
    /// reset a view-backed layer's model transform during a layout pass, so
    /// a finished slide would otherwise show the page back at 0 for the
    /// frames before its completion removes it (the old rows drawn over the
    /// new list).
    private func translate(_ view: NSView, _ x: CGFloat, animated spring: MotionSpring?, from: CGFloat? = nil) {
        guard let layer = view.layer else { return }
        let keyPath = "transform.translation.x"
        let shown = ((layer.presentation() ?? layer).value(forKeyPath: keyPath) as? NSNumber).map { CGFloat($0.doubleValue) } ?? 0
        let start = from ?? shown
        layer.removeAnimation(forKey: Self.slideKey)
        Motion.transaction(nil) { layer.setValue(x, forKeyPath: keyPath) }
        guard let spring, Motion.animatesMovement, start != x else { return }
        let parameters = Motion.spring(spring)
        let animation = CASpringAnimation(keyPath: keyPath)
        animation.mass = 1
        animation.stiffness = parameters.stiffness
        animation.damping = parameters.damping
        animation.duration = parameters.settlingTime(within: 0.002)
        animation.fromValue = start
        animation.toValue = x
        animation.fillMode = .forwards
        animation.isRemovedOnCompletion = false
        layer.add(animation, forKey: Self.slideKey)
    }

    // MARK: Switch by dot, key or a new space

    /// The old space's rows as a page for a slide (call before the reload):
    /// real row views, so text and badges show as they were.
    func prepareSlide(oldSections: [SidebarSection]) {
        finishSlide()
        guard pendingTarget == nil, pager == nil else { return }
        snapshot = makePage(oldSections)
    }

    private func makePage(_ sections: [SidebarSection]) -> SpacePageView {
        let model = SidebarModel(sections: sections)
        model.showWorkspaceTabs = host.model.showWorkspaceTabs
        model.collapsedWorkspaces = host.model.collapsedWorkspaces
        model.workspaceRow = host.model.workspaceRow
        model.activeWorkspaceID = host.model.activeWorkspaceID
        let list = SidebarListView(model: model)
        let container = SpacePageView(frame: page.frame)
        container.wantsLayer = true
        list.frame = container.bounds
        list.autoresizingMask = [.width]
        container.addSubview(list)
        container.list = list
        return container
    }

    /// Slides the kept page out and the reloaded list in from `direction`
    /// (+1: the trailing edge, a later dot); reduced motion cross-fades.
    func slide(direction: Int) {
        guard let snapshot, direction != 0 else { return finishSlide() }
        (page.superview ?? host).addSubview(snapshot, positioned: .above, relativeTo: page)
        (snapshot as? SpacePageView)?.list?.reload(animated: false)
        host.clipsToBounds = true
        page.wantsLayer = true
        CATransaction.begin()
        CATransaction.setCompletionBlock { MainActor.assumeIsolated { [weak self] in self?.finishSlide() } }
        if Motion.animatesMovement {
            let d = CGFloat(direction) * width
            translate(snapshot, -d, animated: .screen, from: 0)
            translate(page, 0, animated: .screen, from: d)
        } else if let layer = snapshot.layer {
            Motion.set(layer, "opacity", to: Float(0), fade: .crossfade, from: Float(1))
        }
        CATransaction.commit()
    }

    private func finishSlide() {
        guard let snapshot else { return }
        snapshot.removeFromSuperview()
        self.snapshot = nil
        if pager == nil, pendingTarget == nil {
            translate(page, 0, animated: nil)
            host.clipsToBounds = false
        }
    }
}

/// A swipe page or the kept page of a slide: drawn only, never hit (the
/// gesture and clicks stay on the list).
final class SpacePageView: NSView {
    var list: SidebarListView?
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
