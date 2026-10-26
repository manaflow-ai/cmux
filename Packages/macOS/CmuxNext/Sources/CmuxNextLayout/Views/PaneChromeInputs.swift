import CmuxNextDesign
import CoreGraphics

/// The state a pane's chrome shows (`PaneHostView.setChrome`): equal inputs show the same ring,
/// dim, border, tab emphasis and attention mark, so the update is skipped.
struct PaneChromeInputs: Equatable {
    var showsRing: Bool
    var dim: CGFloat
    var dimFill: PaneOverlayView.DimFill
    var focusRing: FocusRingSettings
    var ringAlphaOverride: CGFloat?
    var tabEmphasis: ChromeEmphasis
    var border: PaneOverlayView.Border
    var attention: AttentionMark?
    var attentionSettings: AttentionSettings
    var readByEntry: Bool
    var focused: Bool
}
