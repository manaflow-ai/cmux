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
    func cmuxMobilePaneLayer() -> some View {
        background(PaneLayerKeeper().frame(width: 0, height: 0).allowsHitTesting(false))
    }
}

private struct PaneLayerKeeper: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> PaneLayerController { PaneLayerController() }
    func updateUIViewController(_ controller: PaneLayerController, context: Context) { controller.watchGestures() }
}

@MainActor
final class PaneLayerController: UIViewController {
    private var link: CADisplayLink?
    /// Frames to keep the bar off this pane after a transition left it on top,
    /// until the bar is hidden (SwiftUI hides it a beat after the transition).
    private var graceUntil: CFTimeInterval = 0
    private var lastTransition: CFTimeInterval = 0
    private weak var maskedBar: UINavigationBar?
    private var watchedGestures: [ObjectIdentifier] = []

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
            // A pop has taken `from` off the stack already (it comes back if
            // the swipe is cancelled).
            let isPop = !navigation.viewControllers.contains(from)
            let top = isPop ? from : to
            guard let topMinX = PaneLayerGeometry.presentedMinX(of: top.view, in: navigation.view) else { return }
            let edge = min(max(topMinX, 0), width)
            // The span of the screen the bar may draw over: its own pane's.
            let visible: ClosedRange<CGFloat> = pane === top ? 0...edge : edge...width
            let paneSpan: ClosedRange<CGFloat> = pane === top ? edge...width : 0...edge
            mask(bar, to: visible, in: navigation.view)
            PaneLayerProbe.shared?.sample(bar: bar, root: navigation.view, paneSpan: paneSpan)
            graceUntil = pane === top ? now + 0.6 : 0
            return
        }
        // Settled. This pane on top: the bar stays off it until SwiftUI hides it.
        if navigation.topViewController === pane, now < graceUntil, !bar.isHidden {
            mask(bar, to: 0...0, in: navigation.view)
            PaneLayerProbe.shared?.sample(bar: bar, root: navigation.view, paneSpan: 0...width)
            return
        }
        unmask()
        // A transition starting a frame or two after its gesture or callback.
        if now - lastTransition > 0.5 { stopTracking() }
    }

    private func mask(_ bar: UINavigationBar, to visible: ClosedRange<CGFloat>, in root: UIView) {
        guard PaneLayerProbe.masks else { return }
        let barMinX = PaneLayerGeometry.presentedMinX(of: bar, in: root) ?? 0
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

    private func unmask() {
        guard let bar = maskedBar else { return }
        if bar.layer.mask != nil { bar.layer.mask = nil }
        maskedBar = nil
    }

    deinit {
        MainActor.assumeIsolated {
            link?.invalidate()
            maskedBar?.layer.mask = nil
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
    #else
    static let shared: PaneLayerProbe? = nil
    static let masks = true
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
