import AppKit
import CmuxNextDesign

/// The native Page Info geometry and colors left after the bubble and its windows moved to React
/// (webviews/src/browser-chrome/page-info): the bubble panel's width, radius and anchor inset, and
/// the omnibar chip's colors. Sizes come from `Metrics`; colors from `Palette` (Ghostty-derived).
enum PageInfoStyle {
    /// The page info bubble is at least 320 points wide.
    static var bubbleWidth: CGFloat { Metrics.density == .compact ? 320 : 344 }
    static var rowInset: CGFloat { Metrics.panelInset }
    /// The bubble page's rows and padding at this density (sent to the page with its state).
    static var rowHeight: CGFloat { Metrics.paletteRowHeight }
    static var rowHeightWithSubtitle: CGFloat { Metrics.sidebarRowHeightWithSubtitle + Metrics.panelInset }
    static var inset: CGFloat { Metrics.panelInset * 2 }
    static var cornerRadius: CGFloat { PopupStyle.standard.cornerRadius }

    static var pressed: NSColor { Palette.pressedFill } // theme-scoped
    static var focusRing: NSColor { Palette.focusRing } // theme-scoped
    static var danger: NSColor { Palette.danger } // theme-scoped
}
