#if os(iOS)
import UIKit

/// Pull to refresh for a list whose screen has the pull-down search drawer
/// (`cmuxMobilePullDownSearch`), drawn in the list under the search field.
///
/// Why not `UIRefreshControl`: when a list is its screen's content scroll view
/// and the navigation bar's search drawer can collapse, UIKit moves the refresh
/// control into the navigation bar, between the title and the drawer. With an
/// inline title the drawer stays put while the list is pulled, so the control
/// is drawn behind the search field; when the refresh starts the bar moves the
/// field down 60 pt in one frame, and when it ends the field and then the rows
/// jump back up (measured per frame on iOS 26.5 and 27 simulators,
/// cmux-next-ios/verify/pull-to-refresh.md). Neither assigning the control as a
/// plain subview nor switching the drawer's collapsing at the top keeps it in
/// the list. This control stays in the list: the bar never moves, and its
/// numbers are the ones UIKit's control uses when it does stay in a list (a
/// search drawer that is always shown): 8 ticks that fill in clockwise as the
/// list is pulled, a refresh at 186 pt of pull, a 60 pt slot under the field
/// while it runs, then the slot closes under the resting rows and the wheel shrinks away.
@MainActor
public final class ListPullToRefresh {
    /// Pull past the list's top that starts a refresh.
    public nonisolated static let triggerDistance: CGFloat = 186
    /// The slot held open under the search field while a refresh runs.
    public nonisolated static let slotHeight: CGFloat = 60

    /// What a pull shows, from how far the list is pulled past its top.
    public struct Pull: Equatable, Sendable {
        /// Ticks shown, 0 to 8.
        public var ticks: Int
        /// Pulled far enough to start a refresh.
        public var triggers: Bool

        public init(distance: CGFloat) {
            // The first tick shows once there is room for it; all 8 show a little before the refresh starts.
            let start: CGFloat = 12
            let full = ListPullToRefresh.triggerDistance - 36
            let fraction = min(max((distance - start) / (full - start), 0), 1)
            ticks = distance <= start ? 0 : max(1, Int((fraction * 8).rounded(.up)))
            triggers = distance >= ListPullToRefresh.triggerDistance
        }
    }

    private weak var scrollView: UIScrollView?
    private let action: () async -> Void
    private let indicator = ListRefreshIndicator()
    /// The inset this control adds while a refresh runs (0 or `slotHeight`).
    private var held: CGFloat = 0
    public private(set) var isRefreshing = false

    public init(scrollView: UIScrollView, action: @escaping () async -> Void) {
        self.scrollView = scrollView
        self.action = action
        indicator.isHidden = true
        scrollView.insertSubview(indicator, at: 0)
    }

    /// Removes the indicator (the list lost its refresh).
    public func detach() {
        stopSliding()
        if held != 0, let scrollView {
            scrollView.contentInset.top -= held
            held = 0
        }
        indicator.removeFromSuperview()
    }

    /// How far the list is pulled past its top, under the bars and the search field.
    private func distance(_ scrollView: UIScrollView) -> CGFloat {
        -(scrollView.contentOffset.y + scrollView.adjustedContentInset.top - held)
    }

    /// Call from `scrollViewDidScroll` and `scrollViewDidChangeAdjustedContentInset`
    /// (the search drawer opening moves the gap's top).
    public func scrolled() {
        guard let scrollView else { return }
        let distance = distance(scrollView)
        layout(scrollView, distance: distance)
        guard !isRefreshing else { return }
        let pull = Pull(distance: distance)
        indicator.showTicks(scrollView.isDragging ? pull.ticks : min(pull.ticks, indicator.shownTicks))
        if scrollView.isDragging, pull.triggers { begin() }
    }

    /// Call from `scrollViewWillEndDragging`: the finger lifts, so the list can
    /// spring back into the slot (or out of it, when the refresh ended under the finger).
    public func willEndDragging(targetContentOffset: UnsafeMutablePointer<CGPoint>) {
        guard let scrollView else { return }
        let wanted: CGFloat = isRefreshing ? Self.slotHeight : 0
        guard wanted != held else { return }
        // Changing the inset under a finger restarts UIKit's rubber band from the new top
        // (the rows jump); with the finger up the bounce simply ends at the new top.
        stopSliding()
        let change = wanted - held
        held = wanted
        scrollView.contentInset.top += change
        let top = -scrollView.adjustedContentInset.top
        if targetContentOffset.pointee.y < top { targetContentOffset.pointee.y = top }
    }

    /// VoiceOver's three-finger scroll down at the top of the list, as `UIRefreshControl` answers it.
    public func accessibilityRefresh() -> Bool {
        guard let scrollView, !isRefreshing, !scrollView.isDragging, distance(scrollView) >= -1 else { return false }
        begin()
        return true
    }

    private func begin() {
        guard let scrollView else { return }
        isRefreshing = true
        indicator.startSpinning()
        // Pulled by a finger: the slot opens when it lifts (`willEndDragging`).
        // Otherwise (VoiceOver) the list moves down to show the wheel.
        if !scrollView.isDragging {
            move(scrollView, inset: Self.slotHeight)
        }
        Task { @MainActor [weak self] in
            await self?.action()
            self?.end()
        }
    }

    private func end() {
        guard isRefreshing, let scrollView else { return }
        isRefreshing = false
        indicator.stopSpinning()
        // Under a finger the slot closes when it lifts (`willEndDragging`).
        guard !scrollView.isDragging else { return }
        move(scrollView, inset: 0)
    }

    /// Opens or closes the slot with the rows moving with it, never jumping. The
    /// list stays at its top every frame while the slot grows or shrinks: scrolling
    /// the rows over the slot instead reads to the navigation bar as scrolling into
    /// the list, and it collapses the search drawer; removing the slot at once lets
    /// UIKit clamp the offset to the new top in one frame.
    private func move(_ scrollView: UIScrollView, inset: CGFloat) {
        stopSliding()
        guard inset != held else { return }
        let resting = scrollView.contentOffset.y <= -scrollView.adjustedContentInset.top + 1
        guard resting, !UIAccessibility.isReduceMotionEnabled, scrollView.window != nil else {
            return setHeld(inset, in: scrollView, pinToTop: resting)
        }
        // The top without the slot, read now with the search drawer open: each frame rests the list
        // there plus the slot. Following the live inset instead would follow the drawer as it gives a
        // little on each frame's scroll, settling with the field a couple of points short.
        slide = Slide(from: held, to: inset, start: CACurrentMediaTime(), top: scrollView.adjustedContentInset.top - held)
        let link = CADisplayLink(target: SlideTarget(self), selector: #selector(SlideTarget.tick(_:)))
        link.add(to: .main, forMode: .common)
        slideLink = link
    }

    /// The slot growing or shrinking, on the theme's smooth spring.
    private struct Slide {
        var from: CGFloat
        var to: CGFloat
        var start: CFTimeInterval
        var top: CGFloat
    }

    private var slide: Slide?
    private var slideLink: CADisplayLink?

    fileprivate func slideFrame() {
        guard let slide, let scrollView else { return stopSliding() }
        // A finger took the list: the slot settles when it lifts (`willEndDragging`).
        guard !scrollView.isDragging else { return stopSliding() }
        let spring = CmuxMobileTheme.standard.motion.smooth
        let elapsed = CACurrentMediaTime() - slide.start
        // A critically damped spring (bounce 0) settling within the spring's duration.
        let omega = 2 * Double.pi / spring.duration
        let progress = elapsed >= spring.duration ? 1 : 1 - (1 + omega * elapsed) * exp(-omega * elapsed)
        let value = slide.from + (slide.to - slide.from) * CGFloat(progress)
        setHeld(value, in: scrollView, pinToTop: false)
        scrollView.contentOffset.y = -(slide.top + value)
        if progress >= 1 { stopSliding() }
    }

    private func stopSliding() {
        slideLink?.invalidate()
        slideLink = nil
        slide = nil
    }

    private func setHeld(_ value: CGFloat, in scrollView: UIScrollView, pinToTop: Bool) {
        let change = value - held
        held = value
        scrollView.contentInset.top += change
        if pinToTop { scrollView.contentOffset.y = -scrollView.adjustedContentInset.top }
    }

    /// The wheel sits in the gap above the rows: centred in it while the gap is
    /// smaller than the slot, then in the slot right under the search field.
    private func layout(_ scrollView: UIScrollView, distance: CGFloat) {
        let gap = max(distance, 0)
        let visible = gap > 0 || isRefreshing || indicator.isCollapsing
        indicator.isHidden = !visible
        guard visible else { return }
        let size = ListRefreshIndicator.side
        // Content coordinates: the rows start at y = 0, the gap's top is at -gap.
        let centerY = -gap + min(max(gap, isRefreshing ? Self.slotHeight : 0), Self.slotHeight) / 2
        indicator.bounds = CGRect(x: 0, y: 0, width: size, height: size)
        indicator.center = CGPoint(x: scrollView.bounds.midX, y: centerY)
    }
}

/// The slide's display-link target, so the link does not keep the control alive.
@MainActor
private final class SlideTarget: NSObject {
    weak var owner: ListPullToRefresh?

    init(_ owner: ListPullToRefresh) {
        self.owner = owner
    }

    @objc func tick(_ link: CADisplayLink) {
        guard let owner else { return link.invalidate() }
        owner.slideFrame()
    }
}

/// The refresh wheel: 8 rounded ticks around a centre, as `UIRefreshControl`
/// draws them (30 pt across, measured on the iOS 27 simulator).
@MainActor
final class ListRefreshIndicator: UIView {
    static let side: CGFloat = 30
    private static let count = 8
    private var ticks: [CAShapeLayer] = []
    private let wheel = CALayer()
    private(set) var shownTicks = 0
    private(set) var isCollapsing = false
    private var collapse: UIViewPropertyAnimator?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        accessibilityIdentifier = "list.refresh"
        layer.addSublayer(wheel)
        for index in 0 ..< Self.count {
            let tick = CAShapeLayer()
            tick.lineCap = .round
            tick.lineWidth = 3.7
            tick.opacity = 0
            // Clockwise from the top.
            let angle = CGFloat(index) / CGFloat(Self.count) * 2 * .pi - .pi / 2
            let path = UIBezierPath()
            let inner: CGFloat = 6, outer: CGFloat = 13.3
            path.move(to: CGPoint(x: cos(angle) * inner, y: sin(angle) * inner))
            path.addLine(to: CGPoint(x: cos(angle) * outer, y: sin(angle) * outer))
            tick.path = path.cgPath
            wheel.addSublayer(tick)
            ticks.append(tick)
        }
        applyColor()
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (self: ListRefreshIndicator, _) in self.applyColor() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        wheel.frame = bounds
        for tick in ticks { tick.position = CGPoint(x: bounds.midX, y: bounds.midY) }
        CATransaction.commit()
    }

    private func applyColor() {
        let color = UIColor.secondaryLabel.resolvedColor(with: traitCollection).cgColor
        for tick in ticks { tick.strokeColor = color }
    }

    /// While pulling: the first `count` ticks, clockwise from the top.
    func showTicks(_ count: Int) {
        guard count != shownTicks, !isCollapsing else { return }
        shownTicks = count
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (index, tick) in ticks.enumerated() { tick.opacity = index < count ? 0.55 : 0 }
        CATransaction.commit()
    }

    /// Refreshing: the wheel turns one tick at a time, its head darkest.
    func startSpinning() {
        collapse?.stopAnimation(true)
        collapse = nil
        isCollapsing = false
        transform = .identity
        alpha = 1
        shownTicks = Self.count
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (index, tick) in ticks.enumerated() {
            // The head is the last tick clockwise; the ones behind it fade.
            let behind = (Self.count - 1 - index)
            tick.opacity = Float(max(1 - Double(behind) * 0.12, 0.16))
        }
        CATransaction.commit()
        // An activity indicator turns under Reduce Motion too (it shows work, not motion);
        // it steps a tick at a time, as UIActivityIndicatorView does.
        let turn = CAKeyframeAnimation(keyPath: "transform.rotation.z")
        turn.values = (0 ... Self.count).map { CGFloat($0) / CGFloat(Self.count) * 2 * .pi }
        turn.calculationMode = .discrete
        turn.duration = 1
        turn.repeatCount = .infinity
        turn.isRemovedOnCompletion = false
        wheel.add(turn, forKey: "turn") // motion: allow activity indicator (shows work; discrete steps, as UIActivityIndicatorView)
    }

    /// Done: the wheel shrinks away (fades under Reduce Motion), as `UIRefreshControl`'s does.
    func stopSpinning() {
        isCollapsing = true
        let theme = CmuxMobileTheme.standard
        let animator = theme.motion.snap.animator()
        let reduce = UIAccessibility.isReduceMotionEnabled
        animator.addAnimations { [weak self] in
            guard let self else { return }
            self.alpha = 0
            if !reduce { self.transform = CGAffineTransform(scaleX: 0.01, y: 0.01) }
        }
        animator.addCompletion { [weak self] position in
            guard let self, position == .end else { return }
            self.reset()
        }
        collapse = animator
        animator.startAnimation()
    }

    private func reset() {
        wheel.removeAnimation(forKey: "turn")
        collapse = nil
        isCollapsing = false
        transform = .identity
        alpha = 1
        shownTicks = -1
        showTicks(0)
        isHidden = true
    }
}
#endif
