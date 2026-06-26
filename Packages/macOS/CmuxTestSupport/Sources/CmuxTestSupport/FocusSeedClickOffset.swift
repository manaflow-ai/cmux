#if DEBUG
public import Foundation

/// The window-content click point for the secondary omnibar fixture input.
///
/// ``GotoSplitUITestRecorder/setupFocusedInput(panel:)`` seeds two page inputs
/// (see ``FocusSeedResult``) and then needs the secondary input's
/// viewport-normalized center mapped into the host window's content
/// coordinates so the UI test can synthesize a click on it. The live AppKit
/// reads (`webView.window`, `webView.convert(_:to:)`, `contentView.bounds`,
/// `window.frame`) stay app-side; this value type owns only the pure geometry
/// transform on the already-resolved frames.
///
/// The math is byte-identical to the legacy inline `AppDelegate` /
/// `GotoSplitUITestRecorder` computation: the failable initializer returns
/// `nil` for exactly the same guard the recorder used (web frame and content
/// taller/wider than one point, and both normalized centers strictly inside
/// `(0, 1)`), which is the case where the recorder leaves its
/// `secondaryClickOffsetX` / `secondaryClickOffsetY` at the `-1` sentinel.
public struct FocusSeedClickOffset: Sendable {
    /// The click x offset in the window's content coordinate space.
    public let x: Double
    /// The click y offset measured from the top of the window
    /// (titlebar height plus the content-space distance from the top).
    public let y: Double

    /// Computes the secondary-input click offset, or returns `nil` when the
    /// inputs fall outside the valid range (matching the legacy guard).
    ///
    /// - Parameters:
    ///   - webFrame: The web view's frame converted into window coordinates.
    ///   - contentHeight: The window content view's height.
    ///   - windowHeight: The window frame's height (used to derive the
    ///     titlebar height as `max(0, windowHeight - contentHeight)`).
    ///   - secondaryCenterX: The secondary input's viewport-normalized center x.
    ///   - secondaryCenterY: The secondary input's viewport-normalized center y.
    public init?(
        webFrame: CGRect,
        contentHeight: Double,
        windowHeight: Double,
        secondaryCenterX: Double,
        secondaryCenterY: Double
    ) {
        guard webFrame.width > 1,
              webFrame.height > 1,
              contentHeight > 1,
              secondaryCenterX > 0,
              secondaryCenterX < 1,
              secondaryCenterY > 0,
              secondaryCenterY < 1 else {
            return nil
        }
        let xInContent = Double(webFrame.minX) + (secondaryCenterX * Double(webFrame.width))
        let yFromTopInWeb = secondaryCenterY * Double(webFrame.height)
        let yInContent = Double(webFrame.maxY) - yFromTopInWeb
        let yFromTopInContent = contentHeight - yInContent
        let titlebarHeight = max(0, windowHeight - contentHeight)
        self.x = xInContent
        self.y = titlebarHeight + yFromTopInContent
    }
}
#endif
