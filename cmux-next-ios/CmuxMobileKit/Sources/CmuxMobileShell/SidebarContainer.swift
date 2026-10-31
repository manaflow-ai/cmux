#if os(iOS)
import CmuxMobileDesign
import Observation
import SwiftUI
import UIKit

private let theme = CmuxMobileTheme.standard

/// SwiftUI's handle on the push-aside drawer (SPEC 3.3). The UIKit container
/// owns the geometry and animation; SwiftUI reads `progress` / `isOpen` and
/// asks for open/close through this model.
@MainActor
@Observable
public final class SidebarModel {
    /// 0 closed ... 1 open (not rubber-banded).
    public internal(set) var progress: CGFloat = 0
    /// The settled state (true while open or animating open).
    public internal(set) var isOpen = false
    /// Whether an interactive open pan may begin (tab root, stack depth 1).
    public var allowsInteractiveOpen = true

    @ObservationIgnored weak var container: SidebarContainerViewController?

    public init() {}

    public func open() { container?.setOpen(true, velocity: 0) }
    public func close() { container?.setOpen(false, velocity: 0) }
    public func toggle() { isOpen ? close() : open() }

    /// Snapshots the current card content and fades it out over `gentle`, so
    /// a team switch crossfades instead of popping.
    public func crossfadeContent() { container?.crossfadeContent() }

    // Programmatic drives of the same tracking code the pan recognizer uses
    // (the DEBUG demo driver records the drawer through these).
    func beginTracking() { container?.beginTracking() }
    func track(translationX: CGFloat) { container?.track(translationX: translationX) }
    func endTracking(velocityX: CGFloat) { container?.endTracking(velocityX: velocityX) }
}

/// Hosts the team sidebar underneath and the tab interface as a card on top.
/// A pan (or the toolbar button) pushes the card aside by `sidebarWidth`, with
/// a velocity-carrying spring, rubber band past the width, scrim, continuous
/// corners, stroke, shadow and sidebar parallax.
final class SidebarContainerViewController: UIViewController, UIGestureRecognizerDelegate {
    private let model: SidebarModel
    private let sidebarController: UIViewController
    private let contentController: UIViewController

    private let shadowView = UIView()
    private let cardView = UIView()
    private let strokeView = UIView()
    private let scrimView = ScrimView()
    private var pan: UIPanGestureRecognizer!

    /// Card translation in points (rubber-banded beyond `sidebarWidth`).
    private var offset: CGFloat = 0
    private var trackingStart: CGFloat = 0
    private var animator: UIViewPropertyAnimator?
    private var wasPastThreshold = false
    private var isTracking = false
    /// Reduce Motion: the drawer settles in place instead of sliding (a drag
    /// still follows the finger). Tests set it.
    var reducesMotion: () -> Bool = { UIAccessibility.isReduceMotionEnabled }

    init(model: SidebarModel, sidebar: UIViewController, content: UIViewController) {
        self.model = model
        self.sidebarController = sidebar
        self.contentController = content
        super.init(nibName: nil, bundle: nil)
        model.container = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private var sidebarWidth: CGFloat { theme.metrics.sidebarWidth(forScreenWidth: view.bounds.width) }
    private var progress: CGFloat { sidebarWidth > 0 ? min(max(offset / sidebarWidth, 0), 1) : 0 }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = theme.colors.bg.uiColor

        addChild(sidebarController)
        sidebarController.view.backgroundColor = theme.colors.bg.uiColor
        view.addSubview(sidebarController.view)
        sidebarController.didMove(toParent: self)

        shadowView.backgroundColor = theme.colors.bg.uiColor
        shadowView.layer.shadowColor = UIColor.black.cgColor
        shadowView.layer.shadowOpacity = theme.metrics.cardShadowOpacity
        shadowView.layer.shadowRadius = theme.metrics.cardShadowRadius
        shadowView.layer.shadowOffset = theme.metrics.cardShadowOffset
        shadowView.layer.cornerRadius = theme.metrics.sidebarCardRadius
        shadowView.layer.cornerCurve = .continuous
        shadowView.isUserInteractionEnabled = false
        view.addSubview(shadowView)

        cardView.clipsToBounds = true
        cardView.layer.cornerCurve = .continuous
        cardView.backgroundColor = theme.colors.bg.uiColor
        view.addSubview(cardView)
        addChild(contentController)
        cardView.addSubview(contentController.view)
        contentController.didMove(toParent: self)

        scrimView.backgroundColor = theme.colors.scrim.uiColor
        scrimView.isAccessibilityElement = true
        scrimView.accessibilityLabel = String(localized: "Close teams")
        scrimView.accessibilityTraits = .button
        scrimView.onActivate = { [weak self] in self?.setOpen(false, velocity: 0) }
        scrimView.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(scrimTapped)))
        cardView.addSubview(scrimView)

        strokeView.isUserInteractionEnabled = false
        strokeView.backgroundColor = .clear
        strokeView.layer.borderWidth = theme.metrics.cardStrokeWidth
        strokeView.layer.cornerRadius = theme.metrics.sidebarCardRadius
        strokeView.layer.cornerCurve = .continuous
        view.addSubview(strokeView)

        pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.delegate = self
        pan.maximumNumberOfTouches = 1
        view.addGestureRecognizer(pan)
        view.addGestureRecognizer(EdgeSwipePriority())
        // UIKit starts closing an open List row as the finger lands, before the pan asks to
        // begin: whether a row was open is read at touch-down.
        view.addGestureRecognizer(TouchDownProbe { [weak self] in self?.noteTouchDown() })

        registerForTraitChanges([UITraitUserInterfaceStyle.self, UITraitAccessibilityContrast.self]) { (self: Self, _) in
            self.strokeView.layer.borderColor = theme.colors.cardStroke.uiColor.resolvedColor(with: self.traitCollection).cgColor
        }
        strokeView.layer.borderColor = theme.colors.cardStroke.uiColor.resolvedColor(with: traitCollection).cgColor
        apply()
        // Closed at launch: the sidebar is out of the accessibility tree
        // and off screen until it opens (SPEC 6).
        publish(open: model.isOpen)
        setSidebarPresent(model.isOpen)
    }

    /// The closed sidebar is hidden, so VoiceOver and the accessibility tree
    /// never reach controls that cannot be seen; it is shown again as soon
    /// as a drag or an open begins.
    private func setSidebarPresent(_ present: Bool) {
        if sidebarController.view.isHidden == present { sidebarController.view.isHidden = !present }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let bounds = view.bounds
        for card in [shadowView, cardView, strokeView] where card.bounds.size != bounds.size {
            let transform = card.transform
            card.transform = .identity
            card.frame = bounds
            card.transform = transform
        }
        contentController.view.frame = cardView.bounds
        scrimView.frame = cardView.bounds
        shadowView.layer.shadowPath = UIBezierPath(roundedRect: bounds, cornerRadius: theme.metrics.sidebarCardRadius).cgPath
        let sidebarTransform = sidebarController.view.transform
        sidebarController.view.transform = .identity
        sidebarController.view.frame = CGRect(x: 0, y: 0, width: sidebarWidth, height: bounds.height)
        sidebarController.view.transform = sidebarTransform
        if animator == nil, !isTracking {
            offset = model.isOpen ? sidebarWidth : 0
            apply()
        }
    }

    override func accessibilityPerformEscape() -> Bool {
        guard model.isOpen else { return false }
        setOpen(false, velocity: 0)
        return true
    }

    // MARK: - Geometry

    /// Writes every derived property from `offset`. Called per frame while
    /// tracking and inside animation blocks while settling.
    private func apply() {
        let p = progress
        let card = CGAffineTransform(translationX: offset, y: 0)
        cardView.transform = card
        shadowView.transform = card
        strokeView.transform = card
        sidebarController.view.transform = CGAffineTransform(translationX: -theme.metrics.sidebarParallax * (1 - p), y: 0)
        scrimView.alpha = p
        strokeView.alpha = p
        shadowView.alpha = p
    }

    private func setCorners(rounded: Bool) {
        cardView.layer.cornerRadius = rounded ? theme.metrics.sidebarCardRadius : 0
    }

    private func publish(open: Bool) {
        model.isOpen = open
        scrimView.isUserInteractionEnabled = open
        contentController.view.accessibilityElementsHidden = open
        sidebarController.view.accessibilityElementsHidden = !open
        scrimView.isAccessibilityElement = open
    }

    // MARK: - Opening and closing

    func setOpen(_ open: Bool, velocity: CGFloat) {
        settle(open: open, velocity: velocity)
    }

    private func settle(open: Bool, velocity: CGFloat) {
        let target: CGFloat = open ? sidebarWidth : 0
        let distance = target - offset
        // UISpringTimingParameters takes velocity relative to the remaining distance.
        let relativeVelocity = abs(distance) > 0.5 ? velocity / distance : 0
        animator?.stopAnimation(true)
        animator = nil
        setCorners(rounded: true)
        setSidebarPresent(true)
        publish(open: open)
        offset = target
        if reducesMotion() {
            apply()
            didSettle(open: open)
            return
        }
        let animator = theme.motion.drawer.animator(initialVelocity: relativeVelocity)
        animator.addAnimations { [weak self] in self?.apply() }
        animator.addCompletion { [weak self] position in
            guard let self, position == .end else { return }
            self.animator = nil
            self.didSettle(open: open)
        }
        animator.isInterruptible = true
        self.animator = animator
        model.progress = open ? 1 : 0
        animator.startAnimation()
    }

    /// The drawer at rest: a closed card loses its corners and the sidebar
    /// leaves the screen and the accessibility tree; an open one takes
    /// VoiceOver's focus.
    private func didSettle(open: Bool) {
        model.progress = progress
        if !open {
            setCorners(rounded: false)
            setSidebarPresent(false)
        }
        if open { UIAccessibility.post(notification: .screenChanged, argument: sidebarController.view) }
    }

    /// Captures the on-screen position (mid-animation included) as the start
    /// of a drag, so grabbing a moving card never jumps.
    func beginTracking() {
        if let animator, animator.state == .active {
            let presented = cardView.layer.presentation()?.affineTransform().tx ?? offset
            animator.stopAnimation(true)
            self.animator = nil
            offset = presented
            apply()
        }
        setCorners(rounded: true)
        setSidebarPresent(true)
        isTracking = true
        trackingStart = offset
        wasPastThreshold = progress > 0.4
    }

    func track(translationX: CGFloat) {
        let width = sidebarWidth
        let raw = trackingStart + translationX
        offset = raw > width ? width + (raw - width) / 3 : max(0, raw)
        apply()
        let past = progress > 0.4
        if past != wasPastThreshold {
            wasPastThreshold = past
            theme.haptics.threshold()
        }
        model.progress = progress
    }

    func endTracking(velocityX: CGFloat) {
        isTracking = false
        let open: Bool
        if velocityX > 300 {
            open = true
        } else if velocityX < -300 {
            open = false
        } else {
            open = progress > 0.4
        }
        settle(open: open, velocity: velocityX)
    }

    func crossfadeContent() {
        guard let snapshot = contentController.view.snapshotView(afterScreenUpdates: false) else { return }
        snapshot.frame = contentController.view.frame
        cardView.insertSubview(snapshot, belowSubview: scrimView)
        let fade = UIViewPropertyAnimator(duration: theme.motion.gentle.duration, dampingRatio: 1) { snapshot.alpha = 0 }
        fade.addCompletion { _ in snapshot.removeFromSuperview() }
        fade.startAnimation()
    }

    @objc private func scrimTapped() {
        setOpen(false, velocity: 0)
    }

    @objc private func handlePan(_ recognizer: UIPanGestureRecognizer) {
        switch recognizer.state {
        case .began:
            cancelCompetingScrolls()
            beginTracking()
        case .changed:
            track(translationX: recognizer.translation(in: view).x)
        case .ended, .cancelled, .failed:
            endTracking(velocityX: recognizer.state == .ended ? recognizer.velocity(in: view).x : 0)
        default:
            break
        }
    }

    // MARK: - Gesture rules

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === pan else { return true }
        let velocity = pan.velocity(in: view)
        guard abs(velocity.x) > 1.5 * abs(velocity.y) else { return false }
        if model.isOpen {
            return velocity.x < 0
        }
        guard velocity.x > 0 else { return false }
        return mayOpen(at: pan.location(in: view))
    }

    /// Whether a rightward pan at `location` may open the closed drawer.
    func mayOpen(at location: CGPoint) -> Bool {
        guard model.allowsInteractiveOpen else { return false }
        guard !touchIsInPushedScreen(location), !touchIsInHorizontalScroller(location) else { return false }
        return !closesOpenRowActions()
    }

    /// Mail and Messages: while a row's swipe actions are open, a rightward
    /// swipe closes them instead of opening the drawer. A `List` row closes
    /// itself on the touch (UIKit); a row outside `List` is closed here.
    /// Returns whether actions were open.
    private func closesOpenRowActions() -> Bool {
        let rows = RowSwipeActions.shared
        let listRowOpen = listRowOpenAtTouchDown || RowSwipeActions.hasOpenListRow(in: contentController.view)
        guard rows.hasOpenRow || listRowOpen else { return false }
        rows.closeAll()
        return true
    }

    /// A `List` row was slid open when the current touch began.
    private var listRowOpenAtTouchDown = false

    private func noteTouchDown() {
        // Only where the drawer could open (closed, on a tab root): no tree walk elsewhere.
        listRowOpenAtTouchDown = !model.isOpen && model.allowsInteractiveOpen
            && RowSwipeActions.hasOpenListRow(in: contentController.view)
    }

    /// The drawer only opens from a tab root. Any navigation controller under
    /// the touch with something to pop (a chat, workspace, diff, settings page,
    /// in any tab's stack) owns the rightward swipe for its back gesture, so
    /// this does not depend on each stack reporting its depth to the shell.
    private func touchIsInPushedScreen(_ point: CGPoint) -> Bool {
        var responder: UIResponder? = view.hitTest(point, with: nil)
        while let current = responder, current !== self {
            if let navigation = current as? UINavigationController, navigation.viewControllers.count > 1 {
                return true
            }
            responder = current.next
        }
        return false
    }

    /// Pushed screens keep the system back swipe: the drawer pan waits for the
    /// navigation pop recognizers to fail.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRequireFailureOf other: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === pan else { return false }
        if other is UIScreenEdgePanGestureRecognizer { return true }
        // A row outside `List` with open actions takes the rightward swipe to close them.
        if other.name == RowSwipeActions.panName { return true }
        var responder: UIResponder? = other.view
        while let current = responder {
            if let navigation = current as? UINavigationController {
                return other === navigation.interactivePopGestureRecognizer || other === navigation.interactiveContentPopGestureRecognizer
            }
            responder = current.next
        }
        return false
    }

    /// Vertical scroll views may start alongside the pan; once the pan wins
    /// they are cancelled so the list does not drift while the card moves.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        gestureRecognizer === pan && other.view is UIScrollView
    }

    private var simultaneousScrollPans: [UIGestureRecognizer] {
        var result: [UIGestureRecognizer] = []
        func walk(_ view: UIView) {
            if let scroll = view as? UIScrollView, scroll.panGestureRecognizer.state == .began || scroll.panGestureRecognizer.state == .changed {
                result.append(scroll.panGestureRecognizer)
            }
            view.subviews.forEach(walk)
        }
        walk(model.isOpen ? sidebarController.view : contentController.view)
        return result
    }

    private func cancelCompetingScrolls() {
        for recognizer in simultaneousScrollPans {
            recognizer.isEnabled = false
            recognizer.isEnabled = true
        }
    }

    private func touchIsInHorizontalScroller(_ point: CGPoint) -> Bool {
        var hit = view.hitTest(point, with: nil)
        while let current = hit, current !== view {
            if let scroll = current as? UIScrollView, scroll.isScrollEnabled,
               scroll.contentSize.width > scroll.bounds.width + 1 {
                return true
            }
            hit = current.superview
        }
        return false
    }
}

/// Gives a pushed screen's back swipe priority over horizontal scrollers at
/// the leading edge (markdown tables, code cards, chip rows). When a touch
/// lands near the edge, each horizontally scrollable view under it waits for
/// the navigation controller's edge pop to fail; the pop fails at once for a
/// touch that is not an edge swipe, so the scroller still scrolls. It never
/// recognizes or delays touches itself.
private final class EdgeSwipePriority: UIGestureRecognizer {
    private static let edgeWidth: CGFloat = 28
    private var linked = NSHashTable<UIGestureRecognizer>.weakObjects()

    init() {
        super.init(target: nil, action: nil)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        defer { state = .failed }
        guard let view, let touch = touches.first else { return }
        let point = touch.location(in: view)
        let leading = view.effectiveUserInterfaceLayoutDirection == .leftToRight ? point.x : view.bounds.width - point.x
        guard leading <= Self.edgeWidth, let hit = view.hitTest(point, with: event) else { return }
        var scrollers: [UIScrollView] = []
        var responder: UIResponder? = hit
        while let current = responder {
            if let scroll = current as? UIScrollView, scroll.contentSize.width > scroll.bounds.width + 1 {
                scrollers.append(scroll)
            }
            if let navigation = current as? UINavigationController, navigation.viewControllers.count > 1 {
                guard let pop = navigation.interactivePopGestureRecognizer else { return }
                for scroll in scrollers where !linked.contains(scroll.panGestureRecognizer) {
                    scroll.panGestureRecognizer.require(toFail: pop)
                    linked.add(scroll.panGestureRecognizer)
                }
                // Waiting is not always enough: over the diff's 2D code view
                // (the page's own scroller) the pop still yielded and the
                // code bounced (round2.md). A scroller at its leading edge has
                // nothing to scroll back to, so it sits this edge touch out.
                for scroll in scrollers where scroll.contentOffset.x <= -scroll.adjustedContentInset.left + 0.5 {
                    scroll.panGestureRecognizer.isEnabled = false
                    scroll.panGestureRecognizer.isEnabled = true
                }
                return
            }
            responder = current.next
        }
    }
}

/// Reports each touch-down and fails at once: it never recognizes, delays
/// or cancels touches.
private final class TouchDownProbe: UIGestureRecognizer {
    private let began: () -> Void

    init(began: @escaping () -> Void) {
        self.began = began
        super.init(target: nil, action: nil)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        began()
        state = .failed
    }
}

/// The scrim over the pushed card. VoiceOver reads it as "Close teams".
private final class ScrimView: UIView {
    var onActivate: (() -> Void)?

    override func accessibilityActivate() -> Bool {
        onActivate?()
        return true
    }
}

/// Bridges the container into SwiftUI.
struct SidebarContainer<Sidebar: View, Content: View>: UIViewControllerRepresentable {
    let model: SidebarModel
    let sidebar: Sidebar
    let content: Content

    func makeUIViewController(context: Context) -> SidebarContainerViewController {
        let sidebarHost = UIHostingController(rootView: sidebar)
        let contentHost = UIHostingController(rootView: content)
        sidebarHost.view.backgroundColor = .clear
        return SidebarContainerViewController(model: model, sidebar: sidebarHost, content: contentHost)
    }

    func updateUIViewController(_ controller: SidebarContainerViewController, context: Context) {}
}
#endif
