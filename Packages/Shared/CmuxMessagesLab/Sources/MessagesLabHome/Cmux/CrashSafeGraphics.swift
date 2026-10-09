import AppKit
import CoreText

// cmux (crash program, plans/cmux-next/crash-elimination.md): Core Graphics and Core
// Text constructors MessagesLab force-unwrapped. Each returns a working value or a
// stated fallback instead of trapping; Tests/MessagesLabHomeTests/CrashSafeGraphicsTests
// pins that every named literal resolves, so the fallbacks never run in practice.

/// The named color spaces MessagesLab draws in.
enum LabColorSpace {
    /// sRGB (device RGB if the name does not resolve).
    static let sRGB: CGColorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    /// Display P3 (device RGB if the name does not resolve).
    static let displayP3: CGColorSpace = CGColorSpace(name: CGColorSpace.displayP3) ?? CGColorSpaceCreateDeviceRGB()
}

/// The system UI font of a kind and size; the system font by name if Core Text
/// returns none for the kind.
func labUIFont(_ type: CTFontUIFontType, _ size: CGFloat) -> CTFont {
    CTFontCreateUIFontForLanguage(type, size, nil) ?? CTFontCreateWithName(".AppleSystemUIFont" as CFString, size, nil)
}

extension CGContext {
    /// Draws `gradient`, or nothing when it could not be built (a `CGGradient`
    /// initializer returned nil for its colors or locations).
    func drawLinearGradient(_ gradient: CGGradient?, start: CGPoint, end: CGPoint, options: CGGradientDrawingOptions) {
        guard let gradient else { return }
        drawLinearGradient(gradient, start: start, end: end, options: options)
    }
}
