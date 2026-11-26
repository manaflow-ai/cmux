import CoreGraphics
import SwiftUI

/// Top/bottom scroll insets the host supplies so interpreted sidebar content
/// rests below the window's titlebar accessory strip and can scroll up into
/// the host's top fade mask instead of being clipped sharply.
///
/// The host (cmux) owns the real chrome metrics, so it injects this through
/// ``SwiftUI/EnvironmentValues/customSidebarContentInsets``. The scrolling
/// containers (the non-split wrapper and each ``ResizableHSplit`` column) read
/// it and apply matching `safeAreaInset`s, mirroring the default workspace
/// sidebar.
public struct CustomSidebarContentInsets: Equatable, Sendable {
    /// Clear space reserved at the top of each scroll region (the titlebar
    /// accessory inset). Content rests below it and fades into it when scrolled.
    public var top: CGFloat
    /// Clear space reserved at the bottom so content dissolves behind the
    /// sidebar footer rather than overlapping it.
    public var bottom: CGFloat

    /// Creates insets for the custom sidebar scroll regions.
    ///
    /// - Parameters:
    ///   - top: Top inset in points (default `0`).
    ///   - bottom: Bottom inset in points (default `0`).
    public init(top: CGFloat = 0, bottom: CGFloat = 0) {
        self.top = top
        self.bottom = bottom
    }

    /// No insets; content sits flush with the sidebar bounds.
    public static let zero = CustomSidebarContentInsets()
}

private struct CustomSidebarContentInsetsKey: EnvironmentKey {
    static let defaultValue = CustomSidebarContentInsets.zero
}

extension EnvironmentValues {
    /// The top/bottom scroll insets applied to interpreted sidebar content.
    public var customSidebarContentInsets: CustomSidebarContentInsets {
        get { self[CustomSidebarContentInsetsKey.self] }
        set { self[CustomSidebarContentInsetsKey.self] = newValue }
    }
}
