public import SwiftUI

/// Applies an optional accessibility identifier to a sidebar resizer handle.
///
/// When `accessibilityIdentifier` is non-`nil` the wrapped content gets that
/// identifier; otherwise the content is returned unchanged so the view tree is
/// byte-identical to applying no modifier at all.
public struct SidebarResizerAccessibilityModifier: ViewModifier {
    /// The accessibility identifier to apply, or `nil` to leave the content untouched.
    public let accessibilityIdentifier: String?

    /// Creates a modifier that conditionally applies an accessibility identifier.
    /// - Parameter accessibilityIdentifier: The identifier to apply, or `nil` to apply none.
    public init(accessibilityIdentifier: String?) {
        self.accessibilityIdentifier = accessibilityIdentifier
    }

    @ViewBuilder
    public func body(content: Content) -> some View {
        if let accessibilityIdentifier {
            content.accessibilityIdentifier(accessibilityIdentifier)
        } else {
            content
        }
    }
}
