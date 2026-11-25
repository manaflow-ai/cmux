#if os(iOS)
import QuartzCore
import SwiftUI
import UIKit

/// A pane that hides the navigation bar and draws its own header (a workspace,
/// an agent chat) is its own layer: through a push or an interactive pop, the
/// shared navigation bar of the pane beside it (the Workspaces title, its
/// "N of M Macs online", its Search drawer) never draws over it.
///
/// Leo, 2026-11-24: "i tried to swipe back as well and saw immediate
/// overlapping text + search bar which made things overlap ... we need to be
/// treating the layers of panes better." UIKit's navigation bar is one view
/// for the whole stack, above the transition: on a pop from a pane that hides
/// it to one that shows it, the bar comes back at full width the moment the
/// swipe starts, over the pane still sliding away. Here, for every frame of a
/// transition this pane is part of, the bar is masked to the part of the
/// screen the bar's own pane shows: left of the top pane's leading edge when
/// this pane is on top, right of it when this pane is under.
public extension View {
    /// `inTransition` (optional) is true while a navigation transition moves this pane (a swipe
    /// back, Back, a push): what rides the keyboard holds still on the page meanwhile.
    func cmuxMobilePaneLayer(inTransition: Binding<Bool>? = nil) -> some View {
        background(PaneLayerKeeper(inTransition: inTransition).frame(width: 0, height: 0).allowsHitTesting(false))
    }
}

private struct PaneLayerKeeper: UIViewControllerRepresentable {
    let inTransition: Binding<Bool>?

    func makeUIViewController(context: Context) -> PaneLayerController { PaneLayerController() }
    func updateUIViewController(_ controller: PaneLayerController, context: Context) {
        controller.reportTransition = inTransition.map { binding in { active in
            if binding.wrappedValue != active { binding.wrappedValue = active }
        } }
        controller.watchGestures()
    }
}

@MainActor
final class PaneLayerController: UIViewController {
    private var link: CADisplayLink?
    /// Frames to keep the bar off this pane after a transition left it on top,
    /// until the bar is hidden (SwiftUI hides it a beat after the transition).
    private var graceUntil: CFTimeInterval = 0
    private var lastTransition: CFTimeInterval = 0
    private weak var maskedBar: UINavigationBar?
    private weak var shiftedBar: UINavigationBar?
    private var watchedGestures: [ObjectIdentifier] = []
    /// Told when a transition starts or stops moving this pane.
    var reportTransition: ((Bool) -> Void)?
    private var reportedTransition = false

    private func report(_ active: Bool) {
        guard !SwipeBackWholePage.legacy, active != reportedTransition else { return }
        reportedTransition = active
        reportTransition?(active)
    }

    override func loadView() {
        view = UIView(frame: .zero)
        view.isUserInteractionEnabled = false
        view.isHidden = true
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        watchGestures()
        startTracking()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if transitionCoordinator?.isAnimated == true { report(true) }
        startTracking()
    }

    override func didMove(toParent parent: UIViewController?) {
        super.didMove(toParent: parent)
        watchGestures()
    }

    /// The interactive pops start transitions without an appearance callback
    /// here until UIKit has begun them: follow their starts too.
    func watchGestures() {
        guard let navigation = navigationController else { return }
        var gestures: [UIGestureRecognizer] = []
        if let pop = navigation.interactivePopGestureRecognizer { gestures.append(pop) }
        if #available(iOS 26.0, *), let content = navigation.interactiveContentPopGestureRecognizer { gestures.append(content) }
        for gesture in gestures where !watchedGestures.contains(ObjectIdentifier(gesture)) {
            gesture.addTarget(self, action: #selector(popGestureChanged(_:)))
            watchedGestures.append(ObjectIdentifier(gesture))
        }
    }

    @objc private func popGestureChanged(_ gesture: UIGestureRecognizer) {
        if gesture.state == .began || gesture.state == .changed { startTracking() }
    }

    private func startTracking() {
        lastTransition = CACurrentMediaTime()
        guard link == nil else { return }
        let link = CADisplayLink(target: PaneLayerTick(self), selector: #selector(PaneLayerTick.tick))
        link.add(to: .main, forMode: .common)
        self.link = link
        tick()
    }

    private func stopTracking() {
        link?.invalidate()
        link = nil
        report(false)
        unshift()
        unmask()
    }

    /// The navigation stack's view controller holding this pane.
    private var pane: UIViewController? {
        var current: UIViewController? = self
        while let controller = current {
            if controller.parent is UINavigationController { return controller }
            current = controller.parent
        }
        return nil
    }

    fileprivate func tick() {
        let now = CACurrentMediaTime()
        guard let navigation = navigationController, let pane else {
            stopTracking()
            return
        }
        let bar = navigation.navigationBar
        let width = navigation.view.bounds.width
        if let coordinator = navigation.transitionCoordinator,
           let from = coordinator.viewController(forKey: .from),
           let to = coordinator.viewController(forKey: .to),
           pane === from || pane === to {
            lastTransition = now
            report(true)
            // A pop has taken `from` off the stack already (it comes back if
            // the swipe is cancelled).
            let isPop = !navigation.viewControllers.contains(from)
            let top = isPop ? from : to
            let under = isPop ? to : from
            guard let topMinX = PaneLayerGeometry.presentedMinX(of: top.view, in: navigation.view) else { return }
            let edge = min(max(topMinX, 0), width)
            // The span of the screen the bar may draw over: its own pane's.
            let visible: ClosedRange<CGFloat> = pane === top ? 0...edge : edge...width
            let paneSpan: ClosedRange<CGFloat> = pane === top ? edge...width : 0...edge
            // The bar belongs to the page under this one: it slides with that page (its parallax),
            // as a page's own header does, instead of standing still at full width over both.
            // UIKit moves the bar itself too (its own show animation): the shift is what is left
            // to put its leading edge on the under page's.
            let presentedTx = (bar.layer.presentation() ?? bar.layer).affineTransform().tx
            let ownMinX = (PaneLayerGeometry.presentedMinX(of: bar, in: navigation.view) ?? 0) - presentedTx
            var barMinX = ownMinX + presentedTx
            if pane === top, PaneLayerProbe.follows,
               let underMinX = PaneLayerGeometry.presentedMinX(of: under.view, in: navigation.view) {
                let target = min(0, underMinX)
                shift(bar, by: max(-width, min(width, target - ownMinX)))
                barMinX = target
            }
            mask(bar, to: visible, in: navigation.view, barMinX: barMinX)
            PaneLayerProbe.shared?.sample(bar: bar, root: navigation.view, paneSpan: paneSpan)
            graceUntil = pane === top ? now + 0.6 : 0
            return
        }
        // Settled: the bar back in place, and the keyboard followed again.
        unshift()
        report(false)
        // This pane on top: the bar stays off it until SwiftUI hides it.
        if navigation.topViewController === pane, now < graceUntil, !bar.isHidden {
            mask(bar, to: 0...0, in: navigation.view,
                 barMinX: PaneLayerGeometry.presentedMinX(of: bar, in: navigation.view) ?? 0)
            PaneLayerProbe.shared?.sample(bar: bar, root: navigation.view, paneSpan: 0...width)
            return
        }
        unmask()
        // A transition starting a frame or two after its gesture or callback.
        if now - lastTransition > 0.5 { stopTracking() }
    }

    /// `barMinX`: the bar's leading edge as it is drawn this frame (with its shift), in `root`.
    private func mask(_ bar: UINavigationBar, to visible: ClosedRange<CGFloat>, in root: UIView, barMinX: CGFloat) {
        guard PaneLayerProbe.masks else { return }
        if PaneLayerProbe.follows { fadeGlass(in: bar, to: visible, barMinX: barMinX) }
        let layer: CALayer
        if let existing = bar.layer.mask, maskedBar === bar {
            layer = existing
        } else {
            layer = CALayer()
            layer.backgroundColor = UIColor.black.cgColor
            bar.layer.mask = layer
            maskedBar = bar
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // Tall enough for the bar's large title and search drawer drawn
        // outside its bounds.
        layer.frame = CGRect(x: visible.lowerBound - barMinX, y: -1000,
                             width: visible.upperBound - visible.lowerBound, height: bar.bounds.height + 2000)
        CATransaction.commit()
    }

    /// Moves the bar with the page it belongs to (its leading edge at `x`).
    private func shift(_ bar: UINavigationBar, by x: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        bar.transform = CGAffineTransform(translationX: x, y: 0)
        CATransaction.commit()
        shiftedBar = bar
    }

    private func unshift() {
        guard let bar = shiftedBar else { return }
        if bar.transform != .identity { bar.transform = .identity }
        shiftedBar = nil
    }

    private func unmask() {
        unfadeGlass()
        guard let bar = maskedBar else { return }
        if bar.layer.mask != nil { bar.layer.mask = nil }
        maskedBar = nil
    }

    /// The bar's Liquid Glass item groups (the trailing filter and compose capsule, the menu
    /// button) draw through a backdrop that the bar's mask does not clip: each is shown only
    /// while it lies wholly inside `visible`, fading in over its last points there, so it is
    /// never drawn over the page that hides the bar (no doubled bars).
    private var fadedGlass: [(view: UIView, alpha: CGFloat, set: CGFloat)] = []

    private func fadeGlass(in bar: UINavigationBar, to visible: ClosedRange<CGFloat>, barMinX: CGFloat) {
        if fadedGlass.isEmpty || fadedGlass.contains(where: { $0.view.superview == nil || !$0.view.isDescendant(of: bar) }) {
            unfadeGlass()
            fadedGlass = PaneLayerGeometry.glassGroups(in: bar).map { ($0, $0.alpha, $0.alpha) }
        }
        for index in fadedGlass.indices {
            let view = fadedGlass[index].view
            // Fade the group only where nobody else changed it since the last frame.
            guard abs(view.alpha - fadedGlass[index].set) < 0.002 else { continue }
            let span = view.convert(view.bounds, to: bar)
            let minX = barMinX + span.minX
            let maxX = barMinX + span.maxX
            let room = min(minX - visible.lowerBound, visible.upperBound - maxX)
            let alpha = fadedGlass[index].alpha * max(0, min(1, room / 24))
            if abs(view.alpha - alpha) >= 0.002 { view.alpha = alpha }
            fadedGlass[index].set = alpha
        }
    }

    private func unfadeGlass() {
        for entry in fadedGlass where abs(entry.view.alpha - entry.set) < 0.002 { entry.view.alpha = entry.alpha }
        fadedGlass = []
    }

    deinit {
        MainActor.assumeIsolated {
            link?.invalidate()
            maskedBar?.layer.mask = nil
            shiftedBar?.transform = .identity
            for entry in fadedGlass where abs(entry.view.alpha - entry.set) < 0.002 { entry.view.alpha = entry.alpha }
        }
    }
}

/// The display link's target, so the link does not keep the controller alive.
@MainActor
private final class PaneLayerTick: NSObject {
    weak var controller: PaneLayerController?
    init(_ controller: PaneLayerController) { self.controller = controller }
    @objc func tick() { controller?.tick() }
}

enum PaneLayerGeometry {
    /// The view's leading edge as drawn this frame (presentation layers, so
    /// mid-animation), in `root`'s coordinates; nil when not inside `root`.
    @MainActor
    static func presentedMinX(of view: UIView, in root: UIView) -> CGFloat? {
        var layer: CALayer? = view.layer
        var x: CGFloat = 0
        while let current = layer, current !== root.layer {
            let drawn = current.presentation() ?? current
            x += drawn.frame.minX
            if let parent = current.superlayer { x -= (parent.presentation() ?? parent).bounds.minX }
            layer = current.superlayer
        }
        return layer == nil ? nil : x
    }

    /// The bar's Liquid Glass groups: the outermost views narrower than most of the bar that
    /// draw a backdrop (a layer the bar's mask does not clip).
    @MainActor
    static func glassGroups(in bar: UINavigationBar) -> [UIView] {
        func drawsBackdrop(_ layer: CALayer, depth: Int) -> Bool {
            if NSStringFromClass(type(of: layer)).contains("Backdrop") { return true }
            guard depth < 8 else { return false }
            return layer.sublayers?.contains { drawsBackdrop($0, depth: depth + 1) } ?? false
        }
        var groups: [UIView] = []
        func walk(_ view: UIView, depth: Int) {
            for sub in view.subviews where !sub.isHidden {
                if sub.bounds.width > 0, sub.bounds.width < bar.bounds.width * 0.6, drawsBackdrop(sub.layer, depth: 0) {
                    groups.append(sub)
                } else if depth < 8 {
                    walk(sub, depth: depth + 1)
                }
            }
        }
        walk(bar, depth: 0)
        return groups
    }

    /// The bar's span as drawn (empty when hidden or transparent), clipped by
    /// its mask, in `root`'s coordinates.
    @MainActor
    static func drawnSpan(of bar: UINavigationBar, in root: UIView) -> ClosedRange<CGFloat>? {
        guard !bar.isHidden, bar.window != nil else { return nil }
        let drawn = bar.layer.presentation() ?? bar.layer
        guard drawn.opacity > 0.05, let minX = presentedMinX(of: bar, in: root) else { return nil }
        var low = minX
        var high = minX + drawn.bounds.width
        if let mask = bar.layer.mask {
            let shown = mask.presentation() ?? mask
            low = max(low, minX + shown.frame.minX)
            high = min(high, minX + shown.frame.maxX)
        }
        return low < high ? low...high : nil
    }
}

/// A page moves as one through a swipe back, a cancelled one and Back (Leo, 2026-11-25: "The
/// swiping back animation has tons of bullshit overlap and weird looking zones esp near composer
/// bar when there's a background it all doesn't move properly"). DEBUG `-CmuxMobileSwipeBackLegacy`
/// turns the whole-page behavior off, for before-and-after recordings (SwipeBackWholePageUITests).
public enum SwipeBackWholePage {
    #if DEBUG
    public static let legacy = CommandLine.arguments.contains("-CmuxMobileSwipeBackLegacy")
    #else
    public static let legacy = false
    #endif
}

/// DEBUG only, `-CmuxMobilePaneLayerProbe`: the most the navigation bar drew
/// over a pane that hides it during a transition, on the
/// `debug.pane-layers` probe as `samples=N overlap=PT`
/// (PaneLayersUITests). `-CmuxMobilePaneLayerNoMask` measures without the
/// mask (the bar as UIKit draws it).
@MainActor
final class PaneLayerProbe {
    #if DEBUG
    static let shared: PaneLayerProbe? = CommandLine.arguments.contains("-CmuxMobilePaneLayerProbe") ? PaneLayerProbe() : nil
    static let masks = !CommandLine.arguments.contains("-CmuxMobilePaneLayerNoMask")
    /// The bar stands still through a swipe back (masked only) under `-CmuxMobileSwipeBackLegacy`.
    static var follows: Bool { !SwipeBackWholePage.legacy }
    #else
    static let shared: PaneLayerProbe? = nil
    static let masks = true
    static let follows = true
    #endif

    private let label = UILabel(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
    private var samples = 0
    private var overlap: CGFloat = 0

    private init() {
        label.isUserInteractionEnabled = false
        label.alpha = 0.02
        label.isAccessibilityElement = true
        label.accessibilityIdentifier = "debug.pane-layers"
        label.accessibilityLabel = "pane layers probe"
        label.accessibilityValue = "samples=0 overlap=0"
    }

    func sample(bar: UINavigationBar, root: UIView, paneSpan: ClosedRange<CGFloat>) {
        if let window = root.window, label.window !== window { window.addSubview(label) }
        samples += 1
        if let span = PaneLayerGeometry.drawnSpan(of: bar, in: root) {
            let over = min(span.upperBound, paneSpan.upperBound) - max(span.lowerBound, paneSpan.lowerBound)
            overlap = max(overlap, over)
        }
        label.accessibilityValue = "samples=\(samples) overlap=\(Int(overlap.rounded(.up)))"
    }
}
#endif
