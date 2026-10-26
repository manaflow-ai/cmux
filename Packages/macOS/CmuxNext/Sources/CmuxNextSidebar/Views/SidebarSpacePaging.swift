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
    /// The last page, kept off screen for the next switch or swipe: its list keeps its row views
    /// (pool), so a page makes no new row views once warm (space-switch-fast: a new list per
    /// switch built every row view, its buttons and their constraints, from scratch).
    private var sparePage: SpacePageView?

    /// The host as a weak reference: an animation completion runs after the host may be gone
    /// (a window closed mid-slide), and reading the unowned `host` then traps.
    private weak var liveHost: SidebarView?

    init(host: SidebarView) {
        self.host = host
        liveHost = host
    }

    private var page: NSView { host.scrollView }
    private var width: CGFloat { max(1, page.frame.width) }

    // MARK: Gesture

    /// Pages from the list and the dots: a trackpad 1:1, a mouse wheel by
    /// one space a notch.
    func attach(list: SidebarScrollView, dots: ProfileBarView) {
        list.onHorizontalScroll = { [weak self] phase, dx, time in self?.scroll(phase, deltaX: dx, time: time) }
        dots.onHorizontalScroll = { [weak self] phase, dx, time in self?.scroll(phase, deltaX: dx, time: time) }
        list.onWheelPage = { [weak self] step in self?.page(by: step) }
        dots.onWheelPage = { [weak self] step in self?.page(by: step) }
    }

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
        guard let pendingTarget else { return false }
        // A direct selection can supersede an in-flight swipe before its
        // original switch callback arrives. Drop the old lock and transition
        // state so later swipes and wheel paging remain available.
        guard pendingTarget == profile else {
            endPaging()
            return false
        }
        endPaging()
        return true
    }

    private func endPaging() {
        pendingTarget = nil
        if let view = neighbor?.view { retire(view) }
        neighbor = nil
        translate(page, 0, animated: nil)
        host.clipsToBounds = false
    }

    private func showNeighbor(_ index: Int?) {
        guard neighbor?.index != index else { return }
        if let view = neighbor?.view { retire(view) }
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
        CATransaction.setCompletionBlock { MainActor.assumeIsolated { [weak self] in if self?.liveHost != nil { completion?() } } } // main-proof: CATransaction.h: the completion block is called on the main thread
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
    /// new list). A move without a spring holds its value the same way
    /// (cx-gq1k): AppKit's geometry pass for a page just inserted at a
    /// swipe's first event reset its transform, so the next space's rows drew
    /// at 0 over the live list until the next event. At 0 nothing is held.
    private func translate(_ view: NSView, _ x: CGFloat, animated spring: MotionSpring?, from: CGFloat? = nil) {
        guard let layer = view.layer else { return }
        let keyPath = "transform.translation.x"
        let shown = ((layer.presentation() ?? layer).value(forKeyPath: keyPath) as? NSNumber).map { CGFloat($0.doubleValue) } ?? 0
        let start = from ?? shown
        layer.removeAnimation(forKey: Self.slideKey)
        Motion.sidebar.transaction(nil) {
            // A page's layer keeps its shift through AppKit's geometry writes.
            (layer as? SpacePageLayer)?.shiftX = x
            layer.setValue(x, forKeyPath: keyPath)
        }
        guard let spring, Motion.sidebar.animatesMovement, start != x else {
            if x != 0 { layer.add(Motion.hold(keyPath, at: x), forKey: Self.slideKey) }
            return
        }
        let animation = Motion.sidebar.springAnimation(spring, keyPath, from: start, to: x)
        animation.fillMode = .forwards
        animation.isRemovedOnCompletion = false
        layer.add(animation, forKey: Self.slideKey)
    }

    // MARK: Mouse wheel

    /// One mouse wheel page (`SpaceWheelPager`): the space beside slides in
    /// like a switch by dot. Past the first or last space nothing moves
    /// (POLISH: no bouncy transforms).
    func page(by step: Int) {
        guard pager == nil, pendingTarget == nil, step != 0 else { return }
        _ = host.model.stepProfile(by: step)
    }

    // MARK: Switch by dot, key or a new space

    /// The old space's rows as a page for a slide (call before the reload):
    /// real row views, so text and badges show as they were.
    func prepareSlide(oldSections: [SidebarSection]) {
        finishSlide()
        guard pendingTarget == nil, pager == nil else { return }
        snapshot = makePage(oldSections, offset: host.scrollView.contentView.bounds.minY)
    }

    /// A page of `sections` scrolled to `offset`, as the list showed them: it makes views for the
    /// rows in the page's frame only (`SidebarListView.pageViewport`), so a switch or a swipe costs
    /// the rows on screen, never every workspace of the space (space-switch-fast).
    private func makePage(_ sections: [SidebarSection], offset: CGFloat = 0) -> SpacePageView {
        let container = sparePage ?? SpacePageView(frame: page.frame)
        sparePage = nil
        let list = container.list ?? SidebarListView(model: SidebarModel())
        let model = list.model
        model.sections = sections
        model.collapsedSections = Set(sections.filter(\.isCollapsed).map(\.id)) // as `SidebarModel(sections:)` sets them
        model.showWorkspaceTabs = host.model.showWorkspaceTabs
        model.collapsedWorkspaces = host.model.collapsedWorkspaces
        (model.workspaceRow, model.rowBadgeStyle) = (host.model.workspaceRow, host.model.rowBadgeStyle)
        (model.minimal, model.expanded) = (host.model.minimal, host.model.expanded)
        model.detailedStatus = host.model.detailedStatus
        model.showsTimestamps = host.model.showsTimestamps
        (model.showsColors, model.colorIndicator) = (host.model.showsColors, host.model.colorIndicator)
        model.showsLocalMachine = host.model.showsLocalMachine
        model.groupHeaderDetails = host.model.groupHeaderDetails
        model.activeWorkspaceID = host.model.activeWorkspaceID
        container.frame = page.frame
        container.wantsLayer = true
        container.layer?.masksToBounds = true
        list.frame = NSRect(x: 0, y: -offset, width: container.bounds.width, height: container.bounds.height)
        list.pageViewport = NSRect(x: 0, y: offset, width: container.bounds.width, height: container.bounds.height)
        list.autoresizingMask = [.width]
        if list.superview !== container { container.addSubview(list) }
        container.list = list
        return container
    }

    /// A page leaves the screen and waits as the spare, at rest (no shift, no fade).
    private func retire(_ view: NSView) {
        view.removeFromSuperview()
        guard let page = view as? SpacePageView else { return }
        if let layer = page.layer {
            layer.removeAllAnimations()
            Motion.sidebar.transaction(nil) {
                (layer as? SpacePageLayer)?.shiftX = 0
                layer.opacity = 1
            }
        }
        sparePage = page
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
        CATransaction.setCompletionBlock { MainActor.assumeIsolated { [weak self] in self?.finishSlide() } } // main-proof: CATransaction.h: the completion block is called on the main thread
        if Motion.sidebar.animatesMovement {
            let d = CGFloat(direction) * width
            translate(snapshot, -d, animated: .screen, from: 0)
            translate(page, 0, animated: .screen, from: d)
        } else if let layer = snapshot.layer {
            Motion.sidebar.set(layer, "opacity", to: Float(0), fade: .crossfade, from: Float(1))
        }
        CATransaction.commit()
    }

    private func finishSlide() {
        guard let snapshot else { return }
        guard liveHost != nil else {
            snapshot.removeFromSuperview()
            self.snapshot = nil
            return
        }
        retire(snapshot)
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
    nonisolated override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func makeBackingLayer() -> CALayer { SpacePageLayer() }
}

/// A page's backing layer: it moves by `shiftX` only. AppKit writes a view's
/// geometry to its layer on the first display pass after the view is
/// inserted, transform included (identity), so a page placed at a swipe's
/// first event went back to 0 in the layer's value (cx-gq1k; the hold
/// animation only kept what the render server shows, and a host without a
/// screen shows nothing). Every transform written here is the page's shift.
nonisolated final class SpacePageLayer: CALayer {
    var shiftX: CGFloat = 0 {
        didSet { super.transform = CATransform3DMakeTranslation(shiftX, 0, 0) }
    }

    override init() { super.init() }

    override init(layer: Any) {
        super.init(layer: layer)
        shiftX = (layer as? SpacePageLayer)?.shiftX ?? 0
    }

    required init?(coder: NSCoder) { super.init(coder: coder) }

    override var transform: CATransform3D {
        get { super.transform }
        set { super.transform = CATransform3DMakeTranslation(shiftX, 0, 0) }
    }

    override func setAffineTransform(_ transform: CGAffineTransform) {
        super.transform = CATransform3DMakeTranslation(shiftX, 0, 0)
    }
}
