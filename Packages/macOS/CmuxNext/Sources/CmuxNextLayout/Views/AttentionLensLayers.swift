import AppKit
import CmuxNextDesign
import QuartzCore

/// The attention ring drawn as a glass lens (`AttentionLensLook`, Leo 2026-11-02: "I want more
/// fisheye!"). Sublayers of the ring's own layer, so the ring's opacity (its swell, blink, pulse,
/// resting strength and dismiss flash) carries the lens with it: this adds no animation, timer or
/// observer of its own. Three parts, all static Core Animation layers composited on the GPU:
///
/// - the band: light the lens bends inward off the rim, an accent inner shadow that fades into
///   the pane over the look's `depth` (the magnified fisheye edge);
/// - the caustic: a thin bright line inside the band, where the lens focuses that light (split
///   into a warm and a cool line under `prism`);
/// - the specular rim: a white line along the stroke's inner edge that catches the light up-left, a third as
///   bright down-right, as the web lens's gloss (cmux#30596).
///
/// `solid` hides all three and the stroke draws opaque, as before.
@MainActor
final class AttentionLensLayers {
    /// Clips the band to the ring's rounded rect, so its inner shadow only falls inward.
    private let band = CALayer()
    private let bandClip = CAShapeLayer()
    private let shade = CAShapeLayer()
    private let caustic = CAShapeLayer()
    private let causticCool = CAShapeLayer()
    private let specular = CAGradientLayer()
    private let specularStroke = CAShapeLayer()

    private(set) var look = AttentionLensLook.solid

    init() {
        band.mask = bandClip
        band.addSublayer(shade)
        shade.shadowOffset = .zero
        shade.fillColor = NSColor.clear.cgColor
        for line in [caustic, causticCool] {
            line.fillColor = nil
            line.lineWidth = 1
        }
        specularStroke.fillColor = nil
        specularStroke.strokeColor = NSColor.white.cgColor
        specular.mask = specularStroke
        specular.locations = [0, 0.38, 0.62, 1]
        for layer in [band, caustic, causticCool, specular] { layer.isHidden = true }
    }

    /// Adds the lens under `ring`'s border: Core Animation draws a layer's border above its sublayers.
    func install(in ring: CALayer) {
        for layer in [band, caustic, causticCool, specular] { ring.addSublayer(layer) }
    }

    /// The layers for the look the ring draws (for tests and `debug.layers`).
    var showsBand: Bool { !band.isHidden }
    var showsCaustic: Bool { !caustic.isHidden }
    var showsChromaticFringe: Bool { !causticCool.isHidden }
    var showsSpecular: Bool { !specular.isHidden }
    var bandDepth: CGFloat { band.isHidden ? 0 : shade.shadowRadius * 2 }

    /// Lays the lens out on a ring of `size` with corner `radius` and stroke `width`, in the ring
    /// layer's own coordinates, for `look`. Called inside the caller's no-actions transaction.
    func layout(size: CGSize, radius: CGFloat, width: CGFloat, look: AttentionLensLook) {
        self.look = look
        let bounds = CGRect(origin: .zero, size: size)
        let glass = look.isGlass && size.width > look.depth * 2 && size.height > look.depth * 2
        band.isHidden = !glass
        specular.isHidden = !glass
        caustic.isHidden = !(glass && look.drawsCaustic)
        causticCool.isHidden = !(glass && look.splitsCaustic)
        guard glass else { return }

        let outline = CGPath(roundedRect: bounds, cornerWidth: radius, cornerHeight: radius, transform: nil)
        band.frame = bounds
        bandClip.frame = bounds
        bandClip.path = outline
        shade.frame = bounds
        // Everything outside the ring's rounded rect: its shadow is what falls inward.
        let outside = CGPath(rect: bounds.insetBy(dx: -look.depth * 3, dy: -look.depth * 3), transform: nil).subtracting(outline)
        shade.path = outside
        shade.shadowPath = outside
        shade.shadowRadius = look.depth / 2
        shade.shadowOpacity = look.bandOpacity

        // The caustic sits a little past halfway into the band, where the falloff is steepest.
        let causticInset = width + look.depth * 0.45
        caustic.frame = bounds
        caustic.path = Self.inset(bounds, by: causticInset - (look.splitsCaustic ? 0.75 : 0), radius: radius)
        causticCool.frame = bounds
        causticCool.path = Self.inset(bounds, by: causticInset + 0.75, radius: radius)

        specular.frame = bounds
        specularStroke.frame = bounds
        // On the stroke's inner edge, where glass catches the light; the border draws above its
        // sublayers, so on the stroke itself it would hide under it.
        let rim = max(1, width * 0.6)
        specularStroke.lineWidth = rim
        specularStroke.path = Self.inset(bounds, by: width + rim / 2, radius: radius)
        // Up-left in the window whichever way this layer tree is flipped.
        let flipped = specular.contentsAreFlipped()
        specular.startPoint = CGPoint(x: 0, y: flipped ? 0 : 1)
        specular.endPoint = CGPoint(x: 1, y: flipped ? 1 : 0)
    }

    /// Colors the lens from the ring's `color`.
    func applyColors(_ color: NSColor) {
        let accent = color.usingColorSpace(.sRGB) ?? color
        shade.shadowColor = accent.cgColor
        let light = accent.blended(withFraction: 0.55, of: .white) ?? accent
        caustic.strokeColor = (look.splitsCaustic
            ? NSColor(srgbRed: 1, green: 0.62, blue: 0.5, alpha: 0.4)
            : light.withAlphaComponent(0.42)).cgColor
        causticCool.strokeColor = NSColor(srgbRed: 0.5, green: 0.78, blue: 1, alpha: 0.4).cgColor
        let peak = look.specularAlpha
        specular.colors = [
            NSColor.white.withAlphaComponent(peak).cgColor,
            NSColor.white.withAlphaComponent(0).cgColor,
            NSColor.white.withAlphaComponent(0).cgColor,
            NSColor.white.withAlphaComponent(peak / 3).cgColor,
        ]
    }

    /// A rounded rect `inset` points inside `bounds`, its corner following the outer one's.
    private static func inset(_ bounds: CGRect, by inset: CGFloat, radius: CGFloat) -> CGPath? {
        let rect = bounds.insetBy(dx: inset, dy: inset)
        guard rect.width > 0, rect.height > 0 else { return nil }
        let corner = max(0, min(radius - inset, min(rect.width, rect.height) / 2))
        return CGPath(roundedRect: rect, cornerWidth: corner, cornerHeight: corner, transform: nil)
    }
}
