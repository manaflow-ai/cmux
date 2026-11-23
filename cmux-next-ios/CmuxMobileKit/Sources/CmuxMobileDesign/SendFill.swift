#if os(iOS)
import Foundation

/// The agent composer's Send fill (Leo, 2026-11-23: "the send button has no reason to be white on
/// whatever"). The chrome's accent is the Mac theme's foreground when the phone follows the Mac,
/// so under a pale theme Send was a near-white disc. Send takes, in order:
///
/// 1. the harness's own colour (Claude's orange), when it has a hue;
/// 2. else the chrome accent, when it has a hue;
/// 3. else no fill of its own (``Pick/glass``): the caller draws the quiet fill with a label glyph.
///
/// A colour with a hue is moved lighter or darker until it stands 3:1 off the ground it sits on
/// (WCAG's bar for a control), and the glyph is black or white, whichever reads better on it. A
/// colour without a hue (white, black, a pale lavender foreground) is never a fill.
public enum CmuxMobileSendFill {
    public enum Source: Equatable, Sendable { case harness, accent }

    public struct Pick: Equatable, Sendable {
        public let fill: CmuxMobileRGBA
        public let ink: CmuxMobileRGBA
        public let source: Source
    }

    /// WCAG's contrast bar for a control against what is next to it.
    public static let minimumContrast = 3.0
    /// The least spread between the brightest and dimmest channel that counts as a hue. A pale
    /// lavender foreground (`#D0D4F5`, 0.14) and the monochrome brand marks have less.
    public static let minimumChroma = 0.3

    /// The fill for `harness` (its brand colour in this appearance, nil when it has none) and
    /// `accent` (the chrome's), on `ground`. Nil: neither has a hue; draw the glass/fill button.
    public static func pick(harness: CmuxMobileRGBA?, accent: CmuxMobileRGBA, ground: CmuxMobileRGBA) -> Pick? {
        if let harness, let fill = usable(harness, on: ground) { return Pick(fill: fill, ink: ink(on: fill), source: .harness) }
        if let fill = usable(accent, on: ground) { return Pick(fill: fill, ink: ink(on: fill), source: .accent) }
        return nil
    }

    /// `color` opaque, moved toward white (on a dark ground) or black (on a light one) until it is
    /// 3:1 off `ground`; nil when it has no hue.
    public static func usable(_ color: CmuxMobileRGBA, on ground: CmuxMobileRGBA) -> CmuxMobileRGBA? {
        let color = CmuxMobileRGBA(red: color.red, green: color.green, blue: color.blue)
        guard chroma(color) >= minimumChroma else { return nil }
        let away = luminance(ground) < 0.18 ? 1.0 : 0.0
        for step in 0 ... 20 {
            let t = Double(step) / 20
            let moved = CmuxMobileRGBA(red: mix(color.red, away, t), green: mix(color.green, away, t), blue: mix(color.blue, away, t))
            if contrast(moved, ground) >= minimumContrast { return chroma(moved) >= minimumChroma ? moved : nil }
        }
        return nil
    }

    /// Black or white, whichever stands further off `fill`.
    public static func ink(on fill: CmuxMobileRGBA) -> CmuxMobileRGBA {
        let black = CmuxMobileRGBA(red: 0, green: 0, blue: 0), white = CmuxMobileRGBA(red: 1, green: 1, blue: 1)
        return contrast(black, fill) >= contrast(white, fill) ? black : white
    }

    public static func chroma(_ color: CmuxMobileRGBA) -> Double {
        max(color.red, color.green, color.blue) - min(color.red, color.green, color.blue)
    }

    /// WCAG 2 relative luminance.
    public static func luminance(_ color: CmuxMobileRGBA) -> Double {
        func linear(_ c: Double) -> Double { c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(color.red) + 0.7152 * linear(color.green) + 0.0722 * linear(color.blue)
    }

    public static func contrast(_ a: CmuxMobileRGBA, _ b: CmuxMobileRGBA) -> Double {
        let la = luminance(a), lb = luminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    private static func mix(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }
}
#endif
