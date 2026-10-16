public import AppKit
public import SwiftUI

/// The macOS Display accessibility settings that change how cmux chrome
/// renders (System Settings > Accessibility > Display).
///
/// Rendering code takes this as a value so its decisions stay pure and
/// testable; only ``current`` reads the live system state.
public struct DisplayAccessibilityOptions: Equatable, Hashable, Sendable {
    /// Increase Contrast: separators and fills should be stronger.
    public var increaseContrast: Bool

    /// Reduce Transparency: translucent chrome should render opaque.
    public var reduceTransparency: Bool

    /// Differentiate Without Color: state must not be signaled by color alone.
    public var differentiateWithoutColor: Bool

    /// Creates a set of display accessibility options.
    public init(
        increaseContrast: Bool = false,
        reduceTransparency: Bool = false,
        differentiateWithoutColor: Bool = false
    ) {
        self.increaseContrast = increaseContrast
        self.reduceTransparency = reduceTransparency
        self.differentiateWithoutColor = differentiateWithoutColor
    }

    /// Every option off (the default macOS configuration).
    public static let standard = Self()

    /// The options currently set in System Settings.
    public static var current: Self {
        let workspace = NSWorkspace.shared
        return Self(
            increaseContrast: workspace.accessibilityDisplayShouldIncreaseContrast,
            reduceTransparency: workspace.accessibilityDisplayShouldReduceTransparency,
            differentiateWithoutColor: workspace.accessibilityDisplayShouldDifferentiateWithoutColor
        )
    }

    /// Posted on `NSWorkspace.shared.notificationCenter` when any option changes.
    public static let didChangeNotification = NSWorkspace.accessibilityDisplayOptionsDidChangeNotification
}

extension View {
    /// Runs `action` with the new options whenever a macOS Display
    /// accessibility setting changes, so chrome can re-resolve live.
    public func onDisplayAccessibilityOptionsChange(
        perform action: @escaping (DisplayAccessibilityOptions) -> Void
    ) -> some View {
        onReceive(
            NSWorkspace.shared.notificationCenter.publisher(for: DisplayAccessibilityOptions.didChangeNotification)
        ) { _ in
            action(.current)
        }
    }
}
