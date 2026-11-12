import AppKit

/// The transcript seen through the header, live: catalyst's fitted model of
/// Messages' header (catalyst/Sources/Header.swift),
/// `out = base + gain * sat(w * blur(s1) + (1 - w) * blur(s2))`, built from
/// render-server backdrops so it follows every scroll and animation with no
/// main-thread work:
///   1. backdrop A: the content behind, Gaussian blur r1, then saturation `sat`;
///   2. backdrop B (opacity 1 - w): the content behind it (A's output), blur r2
///      (blur(r2) of blur(r1) is close to blur(r2) for r2 >> r1);
///   3. a flat layer of grey `c` at opacity `a`: out = (1 - a) * mix + a * c,
///      so gain = 1 - a and base = a * c.
///   4. the edge line: one device pixel at the header's bottom (white over dark, black over light).
/// An optional fade masks the bottom `fade` points. No glass.
///
/// Private API: CABackdropLayer and CAFilter (QuartzCore), looked up at run
/// time. They are what NSVisualEffectView uses; the public NSVisualEffectView
/// materials did not match (README: header material scores). Fallback when
/// either class is missing: no backdrop and no edge line (the controls over sharp rows).
final class HeaderBackdropView: NSView {
    struct Params {
        var height: CGFloat = 80
        /// Fitted on macOS 27 (2026-10-14, cx-3cb header-parity): the gate's 18:00 scene
        /// (deactivate-activate tp1200ms inactive, tp0000ms active) on ours' sharp rows under the
        /// header (--no-header-backdrop) with the rows above the visible ones where the real AX
        /// frames put them ("The photo failed..." at y 6.5-52.5 pt; ours drew it 24 pt higher,
        /// which biased the earlier fit to a base 2.9 levels too bright); controls masked. The fit
        /// corrects ours' own render of the old parameters by the model's change, so the
        /// render-server blur's edges and the content under the controls cancel: blur 3.5 pt and
        /// 30 pt, w 0.543, gain 0.371, base 26.55 levels, saturation 1.2. Renders of that content,
        /// header region (still gate's metric) against tp1200ms / tp0000ms: saturation 1.0
        /// 2.106 / -, 1.2 1.540 / 1.802, 1.4 1.496 / 1.885; the old parameters 3.347 / -.
        /// macOS 26 keeps the 2026-10-06 values (fitted on macOS 27 frames with the rows above
        /// misplaced: r1 4, r2 34, w 0.543, gain 0.396, base 27.34; no saturation, no edge line):
        /// there is no macOS 26 Messages header reference to fit or check a change against, and
        /// Messages' header differs between 26 and 27 (ComposeMetrics.macOS26, the OS split of the
        /// other fits). (catalyst's macOS 26 fit: r1 4, r2 26, w 0.531, gain 0.338, base 23.65.)
        static let macOS26 = ComposeMetrics.macOS26
        var r1: CGFloat = Params.macOS26 ? 4 : 3.5
        var r2: CGFloat = Params.macOS26 ? 34 : 30
        var w: CGFloat = 0.543
        /// Tint: gain = 1 - a, base = a * c.
        var a: CGFloat = Params.macOS26 ? 1 - 0.396 : 1 - 0.371
        var c: CGFloat = Params.macOS26 ? 27.34 / 255 / (1 - 0.396) : 26.55 / 255 / (1 - 0.371)
        /// Saturation of the blurred mix (CAFilter colorSaturate after A's blur; B blurs A's
        /// output, and a colour matrix commutes with a blur, so the whole mix is saturated; exact
        /// when A's output is not clamped: a saturated blue goes past 1 and may clip; the fit used
        /// the render server's own output, so the numbers include that; 1: none).
        var sat: CGFloat = Params.macOS26 ? 1 : 1.2
        var fade: CGFloat = 0
        /// The header's bottom edge line: one device pixel of white at this opacity over the
        /// backdrop (macOS 27, deactivate-activate tp1200ms and tp0000ms: the last pixel row of
        /// the 80 pt header is (1 - 0.097) * under + 0.097 * 255 over grey and blue rows alike,
        /// active and inactive; 0: no line). Dark only: the light line is fixed at black 0.102 (setLight).
        var line: CGFloat = Params.macOS26 ? 0 : 0.097

        static func fromArguments() -> Params {
            var p = Params()
            let args = ProcessInfo.processInfo.arguments
            func v(_ k: String) -> CGFloat? { args.firstIndex(of: k).flatMap { args.dropFirst($0 + 1).first }.flatMap { Double($0) }.map { CGFloat($0) } /* no index math */ }
            if let x = v("--hb-height") { p.height = x }
            if let x = v("--hb-r1") { p.r1 = x }
            if let x = v("--hb-r2") { p.r2 = x }
            if let x = v("--hb-w") { p.w = x }
            if let x = v("--hb-a") { p.a = x }
            if let x = v("--hb-c") { p.c = x }
            if let x = v("--hb-fade") { p.fade = x }
            if let x = v("--hb-sat") { p.sat = x }
            if let x = v("--hb-line") { p.line = x }
            return p
        }
    }

    let params = Params.fromArguments()
    /// cmux: internal, for the top fade (HeaderFade.swift).
    let root = CALayer()
    private var a: CALayer?, b: CALayer?
    private let tint = CALayer()
    private let edgeLine = CALayer()
    private let fadeMask = CAGradientLayer()
    private(set) var available = false
    /// cmux: the light top fade that replaces the blur (HeaderFade.swift);
    /// nil keeps MessagesLab's always-on blurred header.
    var topFade: CAGradientLayer?
    /// cmux: the length of the last show or hide of the top fade.
    var lastFadeDuration: TimeInterval = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        root.isGeometryFlipped = true
        root.actions = ["bounds": NSNull(), "position": NSNull(), "sublayers": NSNull()]
        layer = root
        wantsLayer = true
        guard ProcessInfo.processInfo.arguments.contains("--no-header-backdrop") == false,
              let a = HeaderBackdropView.backdrop(radius: params.r1, saturation: params.sat), let b = HeaderBackdropView.backdrop(radius: params.r2) else { return }
        available = true
        b.opacity = Float(1 - params.w)
        tint.backgroundColor = NSColor(white: params.c, alpha: 1).cgColor
        tint.opacity = Float(params.a)
        for l in [a, b, tint] {
            l.actions = ["bounds": NSNull(), "position": NSNull()]
            root.addSublayer(l)
        }
        self.a = a; self.b = b
        edgeLine.backgroundColor = NSColor(white: 1, alpha: params.line).cgColor
        edgeLine.actions = ["bounds": NSNull(), "position": NSNull()]
        edgeLine.isHidden = params.line <= 0
        root.addSublayer(edgeLine)
        if params.fade > 0 {
            fadeMask.colors = [NSColor.black.cgColor, NSColor.black.cgColor, NSColor.clear.cgColor]
            root.mask = fadeMask
        }
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsLayout = true
    }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Light appearance: the same blend toward a light grey (out = base + gain * blur, base =
    /// a * c): c from Apple's light window background (white) so base = a * 1. The tint and the
    /// saturation are UNVERIFIED against a light capture of Messages (appearance-light shows
    /// another conversation; only its edge line is measured); the dark c is the fitted macOS 27 value.
    func setLight(_ light: Bool) {
        let c = light ? 1 : params.c
        CATransaction.begin(); CATransaction.setDisableActions(true)
        tint.backgroundColor = NSColor(white: c, alpha: 1).cgColor
        // The edge line in light appearance is black at 0.102 (macOS 27, appearance-light light-inactive
        // and light-active: 255 -> 229 in the last pixel row of the header).
        edgeLine.backgroundColor = (light ? NSColor(white: 0, alpha: 0.102) : NSColor(white: 1, alpha: params.line)).cgColor
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for l in [a, b, tint, topFade].compactMap({ $0 }) { l.frame = bounds }
        // One device pixel at the header's bottom (the view's scale: a window on a 1x display draws 1 pt).
        let px = 1 / max(1, window?.backingScaleFactor ?? 2)
        edgeLine.frame = CGRect(x: 0, y: params.height - px, width: bounds.width, height: px)
        fadeMask.frame = bounds
        let h = max(1, bounds.height)
        let solid = (params.height) / h
        fadeMask.locations = [0, NSNumber(value: Double(solid)), 1]
        CATransaction.commit()
    }

    /// cmux: the tint in the theme's background, so the header over empty
    /// transcript is the background itself (Messages' grey `c` read as a
    /// lighter band on a darker cmux pane); rows under it keep the fitted
    /// gain (1 - a) and blur. A clear background (see-through window)
    /// leaves the blur alone.
    func setTint(_ color: NSColor) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        tint.backgroundColor = color.withAlphaComponent(1).cgColor
        tint.opacity = Float(params.a * color.alphaComponent)
        CATransaction.commit()
    }

    /// The view's height: the header plus its fade.
    var totalHeight: CGFloat { params.height + params.fade }

    /// A CABackdropLayer with a Gaussian blur and, unless `saturation` is 1, a colorSaturate
    /// after it (private QuartzCore classes).
    static func backdrop(radius: CGFloat, saturation: CGFloat = 1) -> CALayer? {
        guard let cls = NSClassFromString("CABackdropLayer") as? CALayer.Type,
              let filterClass = NSClassFromString("CAFilter") as? NSObject.Type else { return nil }
        let sel = NSSelectorFromString("filterWithType:")
        func filter(_ type: String) -> NSObject? {
            guard filterClass.responds(to: sel) else { return nil }
            return filterClass.perform(sel, with: type)?.takeUnretainedValue() as? NSObject
        }
        let l = cls.init()
        guard let f = filter("gaussianBlur") else { return nil }
        f.setValue(radius, forKey: "inputRadius")
        f.setValue(true, forKey: "inputNormalizeEdges")
        var filters: [NSObject] = [f]
        if saturation != 1, let s = filter("colorSaturate") { // nil only if filterWithType: does: the blur stays unsaturated
            // crash-allow: KVC on the CAFilter made above; inputAmount is colorSaturate's input, the same exposure as inputRadius.
            s.setValue(saturation, forKey: "inputAmount")
            filters.append(s)
        }
        l.filters = filters
        if l.responds(to: NSSelectorFromString("setScale:")) { l.setValue(1.0, forKey: "scale") }
        return l
    }
}
