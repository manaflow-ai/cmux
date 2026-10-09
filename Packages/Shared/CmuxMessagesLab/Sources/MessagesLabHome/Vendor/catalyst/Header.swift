#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif
import CoreImage

/// Header: blurred, darkened copy of the transcript under it, the contact
/// avatar and name pill, and the video-call button.
final class HeaderView: UIView {
    weak var source: UIView?
    var title = "Instinct" { didSet { HeaderView.currentTitle = title; overlay.setNeedsDisplay() } }
    fileprivate static var currentTitle = "Instinct"
    private let backdrop = UIImageView()
    private let overlay: CanvasView
    // Display P3: the same transfer curve as sRGB (the fitted blur is unchanged for
    // greys) without clipping the P3 blues under the header.
    private static let ci = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.displayP3)!,
                                                .outputColorSpace: CGColorSpace(name: CGColorSpace.displayP3)!])
    // Fitted to the reference header (least squares over three frames):
    // out = base + gain * (w * blur(s1) + (1 - w) * blur(s2)), sigmas in 2x px.
    static let blurSigma1: Double = 5.3
    static let blurSigma2: Double = 38.9
    static let blurWeight1: CGFloat = 0.531
    static let contentGain: CGFloat = 0.338
    static let baseLevel: CGFloat = 23.65 / 255

    override init(frame: CGRect) {
        overlay = CanvasView(drawer: { ctx, b in HeaderView.drawOverlay(ctx, b) })
        super.init(frame: frame)
        clipsToBounds = true
        backgroundColor = UIColor(white: HeaderView.baseLevel / (1 - HeaderView.contentGain), alpha: 1)
        backdrop.alpha = HeaderView.contentGain
        layer.contentsScale = Fixture.renderScale
        addSubview(backdrop)
        addSubview(overlay)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        backdrop.frame = bounds
        overlay.frame = bounds
    }

    /// Re-render the blurred backdrop from the transcript's current layout.
    /// Live mode uses the system material (composited by the window server,
    /// no per-frame CPU work); capture keeps the fitted blur for determinism.
    var useSystemBlur = false {
        didSet {
            guard useSystemBlur != oldValue else { return }
            if useSystemBlur {
                let v = UIVisualEffectView(effect: UIBlurEffect(style: .systemThickMaterialDark))
                v.frame = bounds
                v.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                insertSubview(v, belowSubview: overlay)
                systemBlur = v
                backdrop.isHidden = true
                backgroundColor = .clear
            } else {
                systemBlur?.removeFromSuperview()
                systemBlur = nil
                backdrop.isHidden = false
                backgroundColor = UIColor(white: HeaderView.baseLevel / (1 - HeaderView.contentGain), alpha: 1)
            }
        }
    }
    private var systemBlur: UIVisualEffectView?

    func refresh() {
        guard let source, !useSystemBlur else { return }
        let scale = Fixture.renderScale
        let pad: CGFloat = 70
        // Outside the window there is nothing to blur, so pad with the
        // background colour (this gives the darker fringe at the edges).
        let rect = CGRect(x: -pad, y: -pad, width: bounds.width + 2 * pad, height: bounds.height + 2 * pad)
        let img = WideBitmap.make(size: rect.size, scale: scale, opaque: true) { c in
            c.setFillColor(Fixture.background.cgColor)
            c.fill(CGRect(origin: .zero, size: rect.size))
            c.translateBy(x: -rect.minX + source.frame.minX - source.bounds.minX, y: -rect.minY + source.frame.minY - source.bounds.minY)
            source.layer.displayRecursively()
            source.layer.render(in: c)
        }
        let cg = img
        let input = CIImage(cgImage: cg).clampedToExtent()
        let w = HeaderView.blurWeight1
        let b1 = input.applyingGaussianBlur(sigma: HeaderView.blurSigma1)
            .applyingFilter("CIColorMatrix", parameters: ["inputRVector": CIVector(x: w, y: 0, z: 0, w: 0),
                                                         "inputGVector": CIVector(x: 0, y: w, z: 0, w: 0),
                                                         "inputBVector": CIVector(x: 0, y: 0, z: w, w: 0)])
        let b2 = input.applyingGaussianBlur(sigma: HeaderView.blurSigma2)
            .applyingFilter("CIColorMatrix", parameters: ["inputRVector": CIVector(x: 1 - w, y: 0, z: 0, w: 0),
                                                         "inputGVector": CIVector(x: 0, y: 1 - w, z: 0, w: 0),
                                                         "inputBVector": CIVector(x: 0, y: 0, z: 1 - w, w: 0)])
        let blurred = b1.applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: b2])
        let crop = CGRect(x: pad * scale, y: pad * scale, width: bounds.width * scale, height: bounds.height * scale)
        // CIImage origin is bottom-left.
        let ciCrop = CGRect(x: crop.minX, y: CGFloat(cg.height) - crop.maxY, width: crop.width, height: crop.height)
        if let out = HeaderView.ci.createCGImage(blurred, from: ciCrop) {
            backdrop.image = UIImage(cgImage: out, scale: scale, orientation: .up)
        }
    }

    static func drawOverlay(_ ctx: CGContext, _ b: CGRect) {
        // Bottom hairline.
        UIColor(white: 1, alpha: 0.09).setFill()
        ctx.fill(CGRect(x: 0, y: 79.5, width: b.width, height: 0.5))
        // Centered items move with the window's center, the video button with its right edge.
        let dx = b.width - Fixture.windowWidth
        ctx.saveGState()
        ctx.translateBy(x: dx / 2, y: 0)
        // Name pill.
        // Pill width follows the title (measured for "Instinct": 77.75 pt).
        let bold = UIFont.systemFont(ofSize: 13, weight: .bold)
        let title = HeaderView.currentTitle
        let tw = TextDraw.width(title, font: bold)
        let pw = tw + 77.75 - TextDraw.width("Instinct", font: bold)
        // Height 28 pt: on luma the pill spans whole device pixels 88-144.
        let pill = CGRect(x: 313.375 - pw / 2, y: 44, width: pw, height: 28)
        Glass.draw(ctx, rect: pill, radius: pill.height / 2, fill: 70, rim: .small)
        TextDraw.line(title, font: bold, color: UIColor(white: 0.93, alpha: 1), x: pill.minX + 11.75, baseline: 63, in: ctx)
        let cx0 = pill.maxX - 12.35
        let chev = UIBezierPath()
        chev.move(to: CGPoint(x: cx0, y: 56.4))
        chev.addLine(to: CGPoint(x: cx0 + 2.6, y: 59.9))
        chev.addLine(to: CGPoint(x: cx0, y: 63.4))
        chev.lineWidth = 1.4
        chev.lineCapStyle = .round
        chev.lineJoinStyle = .round
        UIColor(white: 0.42, alpha: 1).setStroke()
        chev.stroke()
        // Avatar (the contact's picture; colours from screencapture -l, Display P3).
        UIColor(white: 1, alpha: 1).setFill()
        UIBezierPath(ovalIn: CGRect(x: 294, y: 8, width: 40, height: 40)).fill()
        // Monogram "I": a thin flared stem (no installed font matched it).
        let stem = UIBezierPath()
        let cx: CGFloat = 314, y0: CGFloat = 17.5, y1: CGFloat = 38, end: CGFloat = 1.4, mid: CGFloat = 0.8
        stem.move(to: CGPoint(x: cx - end, y: y0))
        stem.addLine(to: CGPoint(x: cx + end, y: y0))
        stem.addQuadCurve(to: CGPoint(x: cx + end, y: y1), controlPoint: CGPoint(x: cx + 2 * mid - end, y: (y0 + y1) / 2))
        stem.addLine(to: CGPoint(x: cx - end, y: y1))
        stem.addQuadCurve(to: CGPoint(x: cx - end, y: y0), controlPoint: CGPoint(x: cx - 2 * mid + end, y: (y0 + y1) / 2))
        stem.close()
        Fixture.p3(7, 10, 9).setFill()
        stem.fill()
        ctx.restoreGState()
        ctx.translateBy(x: dx, y: 0)
        // Video button.
        // Height 36 pt: on luma the button spans whole device pixels 16-88.
        Glass.draw(ctx, rect: CGRect(x: 583.75, y: 8, width: 36.25, height: 36), radius: 18, fill: 55, rim: .button)
        let cfg = UIImage.SymbolConfiguration(pointSize: 18, weight: .regular)
        if let video = UIImage(systemName: "video", withConfiguration: cfg)?.withTintColor(.white, renderingMode: .alwaysOriginal) {
            let s = video.size
            video.draw(in: CGRect(x: 601.9 - s.width / 2, y: 25.75 - s.height / 2, width: s.width, height: s.height))
        }
    }
}

/// Window chrome: traffic lights and the 1 pt light border.
final class ChromeView: UIView {
    var drawsTrafficLights = true { didSet { canvas.setNeedsDisplay() } }
    /// The view's left edge is the window's left edge (true), or it meets a sidebar (false: the
    /// border has no left side and square left corners; only the window's edges get the line).
    var leadingEdgeIsWindowEdge = true { didSet { if leadingEdgeIsWindowEdge != oldValue { canvas.setNeedsDisplay() } } }
    private let canvas = CanvasView()
    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        addSubview(canvas)
        // cmux: weak capture, not unowned (crash program: no trap after the view is freed).
        canvas.drawer = { [weak self] ctx, b in
            guard let self else { return }
            if self.drawsTrafficLights {
                // Measured top/bottom colours of each glassy light, plus a light rim.
                let colors: [((CGFloat, CGFloat, CGFloat), (CGFloat, CGFloat, CGFloat))] = [
                    ((246, 77, 68), (233, 90, 81)), ((249, 170, 0), (250, 196, 27)), ((30, 184, 3), (65, 185, 42))]
                let space = CGColorSpace(name: CGColorSpace.sRGB)
                // Inactive window: grey lights (measured centre 100, rim lighter).
                let grey: ((CGFloat, CGFloat, CGFloat), (CGFloat, CGFloat, CGFloat)) = ((92, 92, 92), (104, 103, 103))
                for (i, c0) in colors.enumerated() {
                    let c = Fixture.inactive ? grey : c0
                    let r = CGRect(x: 18.75 + CGFloat(i) * 23, y: 18.75, width: 14, height: 14)
                    func col(_ v: (CGFloat, CGFloat, CGFloat)) -> CGColor {
                        UIColor(red: v.0 / 255, green: v.1 / 255, blue: v.2 / 255, alpha: 1).cgColor
                    }
                    ctx.saveGState()
                    UIBezierPath(ovalIn: r).addClip()
                    let g = CGGradient(colorsSpace: space, colors: [col(c.0), col(c.1)] as CFArray, locations: [0.15, 0.85])!
                    ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: r.minY), end: CGPoint(x: 0, y: r.maxY), options: [])
                    ctx.restoreGState()
                    UIColor(white: 1, alpha: 0.35).setStroke()
                    let rim = UIBezierPath(ovalIn: r.insetBy(dx: 0.35, dy: 0.35))
                    rim.lineWidth = 0.7
                    rim.stroke()
                }
            }
            UIColor(white: 1, alpha: 0.075).setStroke()
            let r = b.insetBy(dx: 0.5, dy: 0.5)
            if self.leadingEdgeIsWindowEdge {
                let border = UIBezierPath(roundedRect: r, cornerRadius: 15.5)
                border.lineWidth = 1
                border.stroke()
            } else {
                // Top edge, right corners and side, bottom edge; the left side meets the sidebar.
                let p = CGMutablePath()
                p.move(to: CGPoint(x: b.minX, y: r.minY))
                p.addArc(tangent1End: CGPoint(x: r.maxX, y: r.minY), tangent2End: CGPoint(x: r.maxX, y: r.maxY), radius: 15.5)
                p.addArc(tangent1End: CGPoint(x: r.maxX, y: r.maxY), tangent2End: CGPoint(x: b.minX, y: r.maxY), radius: 15.5)
                p.addLine(to: CGPoint(x: b.minX, y: r.maxY))
                ctx.addPath(p)
                ctx.setLineWidth(1)
                ctx.strokePath()
            }
        }
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layoutSubviews() {
        super.layoutSubviews()
        canvas.frame = bounds
    }
}

extension CALayer {
    /// Make sure every layer that draws its own content has drawn it.
    func displayRecursively() {
        displayIfNeeded()
        sublayers?.forEach { $0.displayRecursively() }
    }
}

/// A view that draws itself with a closure (header overlay, chrome, thread rows).
class CanvasView: UIView {
    var drawer: (CGContext, CGRect) -> Void = { _, _ in }
    init(frame: CGRect = .zero, drawer: @escaping (CGContext, CGRect) -> Void = { _, _ in }) {
        self.drawer = drawer
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        layer.contentsScale = Fixture.renderScale
        contentMode = .redraw
        clipsToBounds = false
    }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        drawer(ctx, bounds)
    }
    /// A canvas draws at the render scale (UIKit would pick the screen's,
    /// which is the same live; test renders keep the reference's 2x).
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if layer.contentsScale != Fixture.renderScale { layer.contentsScale = Fixture.renderScale; setNeedsDisplay() }
    }
}
