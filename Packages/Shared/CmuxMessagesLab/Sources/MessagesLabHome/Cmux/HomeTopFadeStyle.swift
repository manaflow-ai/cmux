import Foundation

/// How Home's chat ends at its top, under the Chief's avatar and "Chief >" pill, as the rows scroll away.
///
/// Lawrence 2026-10-23 ("make variations of how we do fade at top in chief"): the glass band
/// (``glassBand``, `HeaderGlassView`) half-showed the text under the pill and tinted it blue. Every
/// style is static while the rows scroll: a mask on the transcript clip (`MessagesWindowView.topMaskStops`)
/// or a backdrop the render server draws, never a per-frame redraw. Under Reduce Transparency the blur
/// styles draw an opaque band in the pane's background instead. Set with
/// `MessagesLabHomeView.setTopFadeStyle(_:)`; a pane with no header (`setBareTop`) keeps its own short fade.
public enum HomeTopFadeStyle: String, Sendable, CaseIterable {
    /// The thin Liquid Glass band to the pill's bottom with a 10 pt soft edge (#23796's look, the default).
    case glassBand
    /// No band: the rows fade out on a tall eased alpha ramp from the pane's top to 24 pt under the pill.
    case softMask
    /// A progressive blur (three stacked render-server blurs, strongest at the top, gone 28 pt under the
    /// pill) plus a short alpha fade at the very top, as macOS 26 and iOS 26 scroll edges.
    case progressiveBlur
    /// An opaque-looking material band to the pill's bottom with a one-pixel hairline, no soft edge.
    case materialHairline
    /// A hard cut at the pill's bottom: no rows above it; a soft shadow under the cut shows only while
    /// rows are scrolled up under it.
    case edgeShadow
    /// No rows under the avatar or the pill at all: the fade starts at the pill's bottom and ramps over 28 pt.
    case belowPill
    /// A gradient of the pane's own background over the rows, solid to the pill's middle, clear 28 pt under
    /// it (a clear background, the see-through window, uses the alpha mask instead).
    case backgroundTint
    /// Messages' own header: the fitted two-radius blur, tint and edge line (`HeaderBackdropView`).
    case messagesBar
}
