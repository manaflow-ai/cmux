#if DEBUG
public import Foundation

/// Pure window target-frame geometry for the terminal cmd-click XCUITest
/// scenario.
///
/// `TerminalCmdClickUITestRecorder` (app target) resolves the live screen
/// frame (`window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame`) and
/// then constructs one of these to compute the target window frame before
/// calling `window.setFrame(_:display:)`. The frame math is a pure function of
/// the resolved screen frame, so it lives here as a tested value type with no
/// AppKit window or live-state coupling.
///
/// ``targetFrame`` reproduces the legacy inline `resizeWindowIfNeeded`
/// computation byte-for-byte: a `min(960, width - 80)` × `min(720, height - 80)`
/// size pinned 40 points inset from the screen's top-left corner. The app-side
/// screen-frame resolution and the `window.frame.equalTo(_:)` guard plus
/// `setFrame` stay app-side, in the original order.
public struct TerminalCmdClickWindowLayout: Sendable {
    /// The resolved screen visible frame the window is laid out within.
    public let screenFrame: CGRect

    /// Creates a layout from the already-resolved screen visible frame.
    ///
    /// - Parameter screenFrame: The screen visible frame
    ///   (`window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame`).
    public init(screenFrame: CGRect) {
        self.screenFrame = screenFrame
    }

    /// The target window frame: a `min(960, width - 80)` × `min(720, height -
    /// 80)` rect pinned 40 points in from the screen's top-left corner.
    public var targetFrame: CGRect {
        let targetSize = CGSize(
            width: min(960, screenFrame.width - 80),
            height: min(720, screenFrame.height - 80)
        )
        let targetOrigin = CGPoint(
            x: screenFrame.minX + 40,
            y: screenFrame.maxY - 40 - targetSize.height
        )
        return CGRect(origin: targetOrigin, size: targetSize)
    }
}
#endif
