import SwiftUI

/// Keeps the cursor affordance tied to the semantic enabled state of a control.
struct PointingHandCursorPolicy {
    static func pointerStyle(
        isEnabled: Bool,
        requested: BackportPointerStyle?
    ) -> BackportPointerStyle? {
        isEnabled ? requested : .default
    }
}

/// Applies the pointing-hand cursor to the rendered body of a primitive button style.
struct PointingHandPrimitiveButtonStyle: PrimitiveButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        DefaultButtonStyle().makeBody(configuration: configuration)
            .backport.pointerStyle(.link)
    }
}

/// Applies the pointing-hand cursor to the default toggle style.
struct PointingHandToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        DefaultToggleStyle().makeBody(configuration: configuration)
            .backport.pointerStyle(.link)
    }
}

extension View {
    /// Applies pointing-hand cursors to controls that use SwiftUI's default
    /// button and toggle styles while preserving disabled controls' arrow cursor.
    func cmuxPointingHandButtons() -> some View {
        buttonStyle(PointingHandPrimitiveButtonStyle())
            .toggleStyle(PointingHandToggleStyle())
    }
}
