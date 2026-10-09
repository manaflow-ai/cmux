import AppKit
import CoreText

// cmux (crash program, plans/cmux-next/crash-elimination.md): constructors the vendored
// sidebar force-unwrapped. Each returns a working value or a stated fallback instead of
// trapping; Tests/MessagesLabSidebarTests/SidebarCrashSafeTests pins that the literals resolve.

/// The system UI font of a kind and size; the system font by name if Core Text returns none.
func sidebarUIFont(_ type: CTFontUIFontType, _ size: CGFloat) -> CTFont {
    CTFontCreateUIFontForLanguage(type, size, nil) ?? CTFontCreateWithName(".AppleSystemUIFont" as CFString, size, nil)
}

extension CGContext {
    /// Draws `gradient`, or nothing when it could not be built.
    func drawLinearGradient(_ gradient: CGGradient?, start: CGPoint, end: CGPoint, options: CGGradientDrawingOptions) {
        guard let gradient else { return }
        drawLinearGradient(gradient, start: start, end: end, options: options)
    }
}
