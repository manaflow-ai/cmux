import AppKit
import CmuxNextDesign

/// Browser chrome sizes, derived only from CmuxNextDesign `Metrics` and
/// `Typography` so a density switch resizes every browser surface. Computed
/// (not stored) because density can change at launch.
enum BrowserMetrics {
    /// Toolbar row: a pane tab strip's height, but never tighter than a
    /// control with a 2 pt margin (28 pt compact).
    static var toolbarHeight: CGFloat { max(Metrics.tabStripHeight, Metrics.controlHeight + Metrics.space2) }
    /// Omnibox capsule and toolbar buttons (24 pt compact).
    static var controlHeight: CGFloat { Metrics.controlHeight }
    static var controlCornerRadius: CGFloat { Metrics.itemCornerRadius }
    /// SF Symbol point size inside controls.
    static var symbolPointSize: CGFloat { Metrics.smallIconSize }
    /// Leading glyph box in the omnibox and suggestion rows.
    static var glyphSize: CGFloat { Metrics.iconSize }

    /// Horizontal padding inside the toolbar and capsules.
    static var toolbarInset: CGFloat { Metrics.space3 }
    static var itemSpacing: CGFloat { Metrics.space3 }
    static var buttonSpacing: CGFloat { Metrics.space1 }

    static var progressThickness: CGFloat { Metrics.space1 }
    static var minimumAddressWidth: CGFloat { Metrics.tabMaxWidth / 2 }

    /// Floating overlays over the page (find bar, prompt bar, dropdown).
    static var overlayInset: CGFloat { Metrics.panelInset }
    static var overlayCornerRadius: CGFloat { Metrics.panelCornerRadius }
    static var overlayPadding: CGFloat { Metrics.space4 }
    static var findBarHeight: CGFloat { toolbarHeight }
    static var findFieldWidth: CGFloat { Metrics.tabMaxWidth * 3 / 4 }
    static var findCountWidth: CGFloat { Metrics.tabMinWidth * 2 }
    static var promptMinWidth: CGFloat { Metrics.paletteWidth / 2 }
    static var promptMaxWidth: CGFloat { Metrics.paletteWidth * 3 / 4 }

    // Type
    static var bodyFont: NSFont { Typography.body }
    static var emphasizedFont: NSFont { Typography.bodyEmphasized }
    static var captionFont: NSFont { Typography.caption }
    static var countFont: NSFont {
        Typography.system(.monospacedDigit, size: Typography.caption.pointSize, weight: .regular)
    }
    static var errorTitleFont: NSFont { Typography.header }
}
