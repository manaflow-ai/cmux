#if os(iOS)
import QuartzCore
import UIKit

/// DEBUG only, `-CmuxMobileWholePageProbe`: whether a pushed page moves as one through a swipe
/// back (Leo, 2026-11-25: "The swiping back animation has tons of bullshit overlap and weird
/// looking zones esp near composer bar when there's a background it all doesn't move properly").
///
/// Every frame of a navigation transition, while the top page's leading edge is between 15% and
/// 85% of the window, it reads the layers as drawn (presentation layers) and keeps the worst of:
/// - `drift`: how far a piece of the top page (its composer, ground, glass, bar) moved against
///   the page's own edge since the transition's first sample: a piece left behind;
/// - `stray`: how far a layer that is in neither page (a container, a window-level backdrop,
///   the tab bar) draws over the top page's span;
/// - `bar`: how far the navigation bar draws over the top page's span while that page hides
///   the bar (its own header is the only one over it).
/// The test (SwipeBackWholePageUITests) reads them on the `debug.whole-page` element as
/// `samples=N drift=PT stray=PT bar=PT` and the worst layer of each.
@MainActor
public final class WholePageProbe {
    #if DEBUG
    static let shared: WholePageProbe? = CommandLine.arguments.contains("-CmuxMobileWholePageProbe") ? WholePageProbe() : nil
    #else
    static let shared: WholePageProbe? = nil
    #endif

    /// Starts the probe when the launch asks for it (DEBUG).
    public static func startIfRequested() { _ = shared }

    private let label = UILabel(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
    private var link: CADisplayLink?
    private var samples = 0
    private var drift: CGFloat = 0
    private var stray: CGFloat = 0
    private var bar: CGFloat = 0
    private var driftName = "-"
    private var strayName = "-"
    private var barName = "-"
    /// Every layer drawn over the top page from outside it, by name: the most it covered and
    /// where (the test attaches them, to name what did not move).
    private var strays: [String: (over: CGFloat, frame: CGRect, path: String)] = [:]
    private var lastGeometry = "-"
    /// The top page's pieces' offsets from its edge at the transition's first sample.
    private var rest: [ObjectIdentifier: CGFloat] = [:]
    private weak var transitionTop: UIViewController?
    /// Whether each settled top page hid the navigation bar.
    private var hidesBar: [ObjectIdentifier: Bool] = [:]

    private init() {
        label.isUserInteractionEnabled = false
        label.alpha = 0.02
        label.isAccessibilityElement = true
        label.accessibilityIdentifier = "debug.whole-page"
        label.accessibilityLabel = "whole page probe"
        publish()
        let link = CADisplayLink(target: WholePageTick(self), selector: #selector(WholePageTick.tick))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    private func publish() {
        let top = strays.sorted { $0.value.over > $1.value.over }.prefix(8).map { name, value in
            "\(name)@\(Int(value.frame.minX)),\(Int(value.frame.minY)),\(Int(value.frame.width))x\(Int(value.frame.height))/\(Int(value.over))[\(value.path)]"
        }.joined(separator: ";")
        label.accessibilityValue = "samples=\(samples) drift=\(Int(drift.rounded(.up))) stray=\(Int(stray.rounded(.up))) "
            + "bar=\(Int(bar.rounded(.up))) driftLayer=\(driftName) strayLayer=\(strayName) barLayer=\(barName) "
            + "geometry=\(lastGeometry) strays=\(top.isEmpty ? "-" : top)"
    }

    /// The names of `layer`'s ancestors' delegates up to the window, outermost last (a short path).
    private static func path(_ layer: CALayer, in space: CALayer) -> String {
        var names: [String] = []
        var current = layer.superlayer
        while let layer = current, layer !== space, names.count < 6 {
            if let delegate = layer.delegate { names.append(String(describing: type(of: delegate))) }
            current = layer.superlayer
        }
        return names.joined(separator: "<")
    }

    fileprivate func tick() {
        guard let window = Self.keyWindow() else { return }
        if label.window !== window { window.addSubview(label) }
        guard let navigation = Self.navigationControllers(in: window.rootViewController).first(where: { nav in
            guard let coordinator = nav.transitionCoordinator else { return false }
            return coordinator.viewController(forKey: .from) != nil && coordinator.viewController(forKey: .to) != nil
        }), let coordinator = navigation.transitionCoordinator,
              let from = coordinator.viewController(forKey: .from), let to = coordinator.viewController(forKey: .to) else {
            // Settled: remember whether each top page hides the bar.
            for navigation in Self.navigationControllers(in: window.rootViewController) {
                if let top = navigation.topViewController {
                    hidesBar[ObjectIdentifier(top)] = navigation.isNavigationBarHidden || navigation.navigationBar.isHidden
                }
            }
            transitionTop = nil
            rest = [:]
            return
        }
        let isPop = !navigation.viewControllers.contains(from)
        let top = isPop ? from : to
        let under = isPop ? to : from
        if top !== transitionTop {
            transitionTop = top
            rest = [:]
        }
        let width = window.bounds.width
        guard let topX = Self.presentedMinX(of: top.view.layer, in: window.layer),
              topX > width * 0.15, topX < width * 0.85 else { return }
        samples += 1
        let page = topX...width
        let underX = Self.presentedMinX(of: under.view.layer, in: window.layer) ?? .nan
        let barX = Self.presentedMinX(of: navigation.navigationBar.layer, in: window.layer) ?? .nan
        func n(_ value: CGFloat) -> String { value.isFinite ? String(Int(value)) : "-" }
        lastGeometry = "top\(n(topX)),under\(n(underX)),bar\(n(barX)),barTx\(n(navigation.navigationBar.transform.tx)),"
            + "mask\(navigation.navigationBar.layer.mask.map { "\(Int($0.frame.minX))+\(Int($0.frame.width))" } ?? "none")"

        // Pieces of the top page that moved against its edge.
        Self.walk(top.view.layer, in: window.layer) { layer, frame in
            guard frame.width >= 24, frame.height >= 24 else { return }
            let id = ObjectIdentifier(layer)
            let offset = frame.minX - topX
            guard let start = rest[id] else {
                rest[id] = offset
                return
            }
            let moved = abs(offset - start)
            if moved > drift {
                drift = moved
                driftName = Self.name(layer)
            }
        }

        // Layers in neither page drawn over the top page (painted after it).
        let skip: Set<ObjectIdentifier> = [ObjectIdentifier(top.view.layer), ObjectIdentifier(under.view.layer),
                                           ObjectIdentifier(navigation.navigationBar.layer), ObjectIdentifier(label.layer)]
        var passedTop = false
        Self.walk(window.layer, in: window.layer, skipping: skip, skipped: { layer in
            if layer === top.view.layer { passedTop = true }
        }) { layer, frame in
            guard passedTop, frame.width >= 8, frame.height >= 8, frame.maxY > 0, frame.minY < window.bounds.height else { return }
            let over = min(frame.maxX, page.upperBound) - max(frame.minX, page.lowerBound)
            // The page's own shadow, a sliver at its edge, is UIKit's.
            guard over > 12 else { return }
            let name = Self.name(layer)
            if over > (strays[name]?.over ?? 0) { strays[name] = (over, frame, Self.path(layer, in: window.layer)) }
            if over > stray {
                stray = over
                strayName = name
            }
        }

        // The bar over a page that hides it.
        if hidesBar[ObjectIdentifier(top)] == true {
            let barLayer = navigation.navigationBar.layer
            // A mask on the bar (the pane layer's) is what it may draw over.
            var shown = page
            if let mask = barLayer.mask, let barX = Self.presentedMinX(of: barLayer, in: window.layer) {
                let drawn = mask.presentation() ?? mask
                let low = max(page.lowerBound, barX + drawn.frame.minX)
                let high = min(page.upperBound, barX + drawn.frame.maxX)
                shown = low < high ? low...high : page.lowerBound...page.lowerBound
            }
            Self.walk(barLayer, in: window.layer) { layer, frame in
                guard frame.width >= 4, frame.height >= 4 else { return }
                let over = min(frame.maxX, shown.upperBound) - max(frame.minX, shown.lowerBound)
                if over > bar {
                    bar = over
                    let drawn = layer.presentation() ?? layer
                    barName = "\(Self.name(layer))@\(Int(frame.minX)),\(Int(frame.width))a\(String(format: "%.2f", drawn.opacity))"
                        + "anim\(layer.animationKeys()?.joined(separator: "+") ?? "-")[\(Self.path(layer, in: barLayer))]"
                }
            }
        }
        publish()
    }

    private static func name(_ layer: CALayer) -> String {
        let delegate = layer.delegate.map { String(describing: type(of: $0)) } ?? String(describing: type(of: layer))
        return delegate.replacingOccurrences(of: " ", with: "")
    }

    /// Visits every visible layer under `root` that draws something, with its frame as drawn in
    /// `space` (presentation layers, so mid-animation). Skips the subtrees in `skipping`, hidden
    /// layers and those drawn at under 5% opacity.
    private static func walk(_ root: CALayer, in space: CALayer, skipping: Set<ObjectIdentifier> = [],
                             skipped: (CALayer) -> Void = { _ in }, _ visit: (CALayer, CGRect) -> Void) {
        guard let origin = presentedOrigin(of: root, in: space) else { return }
        let opacity = presentedOpacity(of: root, in: space)
        func go(_ layer: CALayer, _ origin: CGPoint, _ opacity: Float) {
            let drawn = layer.presentation() ?? layer
            guard !drawn.isHidden, opacity * drawn.opacity > 0.05 else { return }
            let alpha = opacity * drawn.opacity
            let frame = CGRect(origin: origin, size: drawn.bounds.size)
            if draws(layer) { visit(layer, frame) }
            for sub in layer.sublayers ?? [] {
                if skipping.contains(ObjectIdentifier(sub)) {
                    skipped(sub)
                    continue
                }
                let subDrawn = sub.presentation() ?? sub
                let subOrigin = CGPoint(x: origin.x + subDrawn.frame.minX - drawn.bounds.minX,
                                        y: origin.y + subDrawn.frame.minY - drawn.bounds.minY)
                go(sub, subOrigin, alpha)
            }
        }
        // `root`'s own opacity is counted in `go`; start from its parent's.
        let own = (root.presentation() ?? root).opacity
        go(root, origin, own > 0 ? opacity / own : 0)
    }

    /// Whether the layer paints: contents, a visible background, a border or a shadow it draws.
    private static func draws(_ layer: CALayer) -> Bool {
        let drawn = layer.presentation() ?? layer
        if drawn.contents != nil { return true }
        if let color = drawn.backgroundColor, color.alpha > 0.05 { return true }
        if drawn.borderWidth > 0, let color = drawn.borderColor, color.alpha > 0.05 { return true }
        let kind = String(describing: type(of: layer))
        return kind.contains("Backdrop") || kind.contains("Glass") || kind.contains("Metal") || layer is CAShapeLayer
            || layer is CATextLayer || layer is CAGradientLayer
    }

    private static func presentedOrigin(of layer: CALayer, in space: CALayer) -> CGPoint? {
        var current: CALayer? = layer
        var point = CGPoint.zero
        while let layer = current, layer !== space {
            let drawn = layer.presentation() ?? layer
            point.x += drawn.frame.minX
            point.y += drawn.frame.minY
            if let parent = layer.superlayer {
                let parentDrawn = parent.presentation() ?? parent
                point.x -= parentDrawn.bounds.minX
                point.y -= parentDrawn.bounds.minY
            }
            current = layer.superlayer
        }
        return current == nil ? nil : point
    }

    private static func presentedMinX(of layer: CALayer, in space: CALayer) -> CGFloat? {
        presentedOrigin(of: layer, in: space)?.x
    }

    private static func presentedOpacity(of layer: CALayer, in space: CALayer) -> Float {
        var current: CALayer? = layer
        var opacity: Float = 1
        while let layer = current, layer !== space {
            let drawn = layer.presentation() ?? layer
            if drawn.isHidden { return 0 }
            opacity *= drawn.opacity
            current = layer.superlayer
        }
        return opacity
    }

    private static func keyWindow() -> UIWindow? {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).first { $0.isKeyWindow }
    }

    private static func navigationControllers(in root: UIViewController?) -> [UINavigationController] {
        guard let root else { return [] }
        var found: [UINavigationController] = []
        var stack: [UIViewController] = [root]
        while let controller = stack.popLast() {
            if let navigation = controller as? UINavigationController { found.append(navigation) }
            stack.append(contentsOf: controller.children)
            if let presented = controller.presentedViewController { stack.append(presented) }
        }
        return found
    }
}

/// The display link's target, so the link does not keep the probe alive.
@MainActor
private final class WholePageTick: NSObject {
    weak var probe: WholePageProbe?
    init(_ probe: WholePageProbe) { self.probe = probe }
    @objc func tick() { probe?.tick() }
}
#endif
