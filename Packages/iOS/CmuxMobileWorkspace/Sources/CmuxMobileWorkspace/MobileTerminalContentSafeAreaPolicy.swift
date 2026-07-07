public import SwiftUI

/// Pure policy computing horizontal content insets that keep terminal content
/// clear of the landscape camera area.
///
/// Only applies in the full-width, compact-height (landscape phone) case. When the
/// safe-area insets are clearly asymmetric, the larger side's delta is used; when
/// they are symmetric and large enough, the configured `symmetricCameraEdge`
/// decides which side to inset.
public struct MobileTerminalContentSafeAreaPolicy {
    private init() {}

    private static let landscapeCameraInsetThreshold: CGFloat = 32
    private static let landscapeCameraInsetDeltaThreshold: CGFloat = 8

    /// Computes the horizontal content insets for the terminal.
    /// - Parameters:
    ///   - context: The terminal's layout context.
    ///   - hasCompactVerticalSize: Whether the vertical size class is compact.
    ///   - safeAreaInsets: The current safe-area insets.
    ///   - symmetricCameraEdge: Which edge to inset when the safe-area insets are symmetric. Defaults to `.trailing`.
    /// - Returns: The content insets to apply, or ``MobileTerminalContentInsets/zero`` when none are needed.
    public static func horizontalInsets(
        context: MobileTerminalSafeAreaContext,
        hasCompactVerticalSize: Bool,
        safeAreaInsets: EdgeInsets,
        symmetricCameraEdge: MobileTerminalLandscapeCameraEdge = .trailing
    ) -> MobileTerminalContentInsets {
        guard context == .fullWidth, hasCompactVerticalSize else {
            return .zero
        }
        let leading = max(0, safeAreaInsets.leading)
        let trailing = max(0, safeAreaInsets.trailing)
        let largestInset = max(leading, trailing)
        guard largestInset >= landscapeCameraInsetThreshold else {
            return .zero
        }
        let insetDelta = abs(leading - trailing)
        if insetDelta >= landscapeCameraInsetDeltaThreshold {
            if leading > trailing {
                return MobileTerminalContentInsets(leading: insetDelta, trailing: 0)
            }
            return MobileTerminalContentInsets(leading: 0, trailing: insetDelta)
        }

        switch symmetricCameraEdge {
        case .leading:
            return MobileTerminalContentInsets(leading: largestInset, trailing: 0)
        case .trailing:
            return MobileTerminalContentInsets(leading: 0, trailing: largestInset)
        case .none:
            return .zero
        }
    }
}
