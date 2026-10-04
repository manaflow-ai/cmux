import AppKit

/// The transcript seen through the header, live: catalyst's fitted model of
/// Messages' header (catalyst/Sources/Header.swift),
/// `out = base + gain * (w * blur(s1) + (1 - w) * blur(s2))`, built from
/// render-server backdrops so it follows every scroll and animation with no
/// main-thread work:
///   1. backdrop A: the content behind, Gaussian blur r1;
///   2. backdrop B (opacity 1 - w): the content behind it (A's output), blur r2
///      (blur(r2) of blur(r1) is close to blur(r2) for r2 >> r1);
///   3. a flat layer of grey `c` at opacity `a`: out = (1 - a) * mix + a * c,
///      so gain = 1 - a and base = a * c.
/// An optional fade masks the bottom `fade` points. No glass, no edge line.
///
/// Private API: CABackdropLayer and CAFilter (QuartzCore), looked up at run
/// time. They are what NSVisualEffectView uses; the public NSVisualEffectView
/// materials did not match (README: header material scores). Fallback when
/// either class is missing: no backdrop (the controls over sharp rows).
final class HeaderBackdropView: NSView {
    struct Params {
        var height: CGFloat = 80
        /// Gaussian radii (points) of the two blurs: catalyst's sigmas (2.65,
        /// 19.45 pt) refit live on cmux-lawrence-2 against the recording
        /// (backdrop area mad 3.26 -> 3.10).
        var r1: CGFloat = 4
        var r2: CGFloat = 26
        var w: CGFloat = 0.531
        /// Tint: gain = 1 - a, base = a * c (catalyst: gain 0.338, base 23.65).
        var a: CGFloat = 1 - 0.338
        var c: CGFloat = 23.65 / 255 / (1 - 0.338)
        var fade: CGFloat = 0

        static func fromArguments() -> Params {
            var p = Params()
            let args = ProcessInfo.processInfo.arguments
            func v(_ k: String) -> CGFloat? { args.firstIndex(of: k).flatMap { $0 + 1 < args.count ? Double(args[$0 + 1]).map { CGFloat($0) } : nil } }
            if let x = v("--hb-height") { p.height = x }
            if let x = v("--hb-r1") { p.r1 = x }
            if let x = v("--hb-r2") { p.r2 = x }
            if let x = v("--hb-w") { p.w = x }
            if let x = v("--hb-a") { p.a = x }
            if let x = v("--hb-c") { p.c = x }
            if let x = v("--hb-fade") { p.fade = x }
            return p
        }
    }

    let params = Params.fromArguments()
    private let root = CALayer()
    private var a: CALayer?, b: CALayer?
    private let tint = CALayer()
    private let fadeMask = CAGradientLayer()
    private(set) var available = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        root.isGeometryFlipped = true
        root.actions = ["bounds": NSNull(), "position": NSNull(), "sublayers": NSNull()]
        layer = root
        wantsLayer = true
        guard ProcessInfo.processInfo.arguments.contains("--no-header-backdrop") == false,
              let a = HeaderBackdropView.backdrop(radius: params.r1), let b = HeaderBackdropView.backdrop(radius: params.r2) else { return }
        available = true
        b.opacity = Float(1 - params.w)
        tint.backgroundColor = NSColor(white: params.c, alpha: 1).cgColor
        tint.opacity = Float(params.a)
        for l in [a, b, tint] {
            l.actions = ["bounds": NSNull(), "position": NSNull()]
            root.addSublayer(l)
        }
        self.a = a; self.b = b
        if params.fade > 0 {
            fadeMask.colors = [NSColor.black.cgColor, NSColor.black.cgColor, NSColor.clear.cgColor]
            root.mask = fadeMask
        }
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for l in [a, b, tint].compactMap({ $0 }) { l.frame = bounds }
        fadeMask.frame = bounds
        let h = max(1, bounds.height)
        let solid = (params.height) / h
        fadeMask.locations = [0, NSNumber(value: Double(solid)), 1]
        CATransaction.commit()
    }

    /// The view's height: the header plus its fade.
    var totalHeight: CGFloat { params.height + params.fade }

    /// A CABackdropLayer with a Gaussian blur (private QuartzCore classes).
    static func backdrop(radius: CGFloat) -> CALayer? {
        guard let cls = NSClassFromString("CABackdropLayer") as? CALayer.Type,
              let filterClass = NSClassFromString("CAFilter") as? NSObject.Type else { return nil }
        let l = cls.init()
        let sel = NSSelectorFromString("filterWithType:")
        guard filterClass.responds(to: sel),
              let f = filterClass.perform(sel, with: "gaussianBlur")?.takeUnretainedValue() as? NSObject else { return nil }
        f.setValue(radius, forKey: "inputRadius")
        f.setValue(true, forKey: "inputNormalizeEdges")
        l.filters = [f]
        if l.responds(to: NSSelectorFromString("setScale:")) { l.setValue(1.0, forKey: "scale") }
        return l
    }
}
