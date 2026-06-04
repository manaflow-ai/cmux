#if canImport(UIKit)
import Foundation

/// Terminal font sizing constants for the iOS app, in points.
///
/// The mobile terminal renders through libghostty at a point size; the Retina
/// pixel multiplier is applied separately via content scale (see the iOS DPI
/// handling in `ghostty/src/font/face.zig`). Every terminal launches at
/// ``defaultSize``, a comfortable reading size for the phone's narrow screen.
/// The *live* size after the user pinches / taps the zoom buttons is
/// owned by the surface (`GhosttySurfaceView.liveFontSize`) and is intentionally
/// NOT persisted across launches: a persisted zoom is what made a fresh launch
/// open with an oversized font. ``minimumSize``/``maximumSize`` bound the zoom.
public struct MobileTerminalFontPreference {
    private init() {}

    /// Point size every terminal opens at. Smaller than the macOS terminal
    /// default (`font-size = 12`) so the phone's narrow screen fits more columns
    /// and rows at launch. iOS renders at the same 72 points-per-inch logical
    /// scale as macOS (see the iOS DPI handling in `ghostty/src/font/face.zig`);
    /// the Retina pixel multiplier is applied separately via content scale.
    public static let defaultSize: Float32 = 10
    /// Smallest size the zoom controls will reach.
    static let minimumSize: Float32 = 8
    /// Largest size the zoom controls will reach.
    static let maximumSize: Float32 = 28
}
#endif
