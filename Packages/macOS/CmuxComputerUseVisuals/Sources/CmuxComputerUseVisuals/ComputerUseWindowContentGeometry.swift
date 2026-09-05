public import CoreGraphics

/// Converts a titled AppKit window's layout rect into flipped view coordinates.
///
/// AppKit reports ``NSWindow/contentLayoutRect`` in a bottom-left coordinate
/// system, while SwiftUI hosting views are flipped. Keeping this conversion in
/// one value type prevents compact artwork from being centered under a title bar.
nonisolated public struct ComputerUseWindowContentGeometry: Sendable {
    /// The hosting view's full bounds in its local (flipped) coordinates.
    public let contentBounds: CGRect
    /// The window's ``contentLayoutRect`` in window coordinates.
    public let contentLayoutRect: CGRect

    /// Creates geometry for one window/content-view pair.
    ///
    /// - Parameters:
    ///   - contentBounds: The full hosting-view bounds.
    ///   - contentLayoutRect: The window layout rect excluding title-bar chrome.
    public init(contentBounds: CGRect, contentLayoutRect: CGRect) {
        self.contentBounds = contentBounds
        self.contentLayoutRect = contentLayoutRect
    }

    /// The visible content rect expressed in the hosting view's flipped space.
    public var visibleContentRect: CGRect {
        CGRect(
            x: contentLayoutRect.minX,
            y: contentBounds.maxY - contentLayoutRect.maxY,
            width: contentLayoutRect.width,
            height: contentLayoutRect.height
        )
    }

    /// Places a visual frame by its visible bounds, not by an asymmetric outer frame.
    ///
    /// - Parameter visibleBounds: The measured artwork bounds relative to its frame.
    /// - Returns: A frame whose visible midpoint equals the visible content midpoint.
    public func centeredFrame(for visibleBounds: CGRect) -> CGRect {
        CGRect(
            x: visibleContentRect.midX - visibleBounds.midX,
            y: visibleContentRect.midY - visibleBounds.midY,
            width: visibleBounds.width,
            height: visibleBounds.height
        )
    }

    /// Places a frame with its origin at zero-relative visible artwork bounds.
    ///
    /// - Parameter size: The measured visual size.
    /// - Returns: A centered frame in hosting-view coordinates.
    public func centeredFrame(for size: CGSize) -> CGRect {
        centeredFrame(for: CGRect(origin: .zero, size: size))
    }
}
