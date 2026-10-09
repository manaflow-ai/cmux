import AppKit
import CoreText

// cmux (crash program, plans/cmux-next/crash-elimination.md): constructors the vendored
// sidebar force-unwrapped (gradients; fonts are SidebarDraw.uiFont). Each returns a working value or a stated fallback instead of
// trapping; Tests/MessagesLabSidebarTests/SidebarCrashSafeTests pins that the literals resolve.

extension CGContext {
    /// Draws `gradient`, or nothing when it could not be built.
    func drawLinearGradient(_ gradient: CGGradient?, start: CGPoint, end: CGPoint, options: CGGradientDrawingOptions) {
        guard let gradient else { return }
        drawLinearGradient(gradient, start: start, end: end, options: options)
    }
}
