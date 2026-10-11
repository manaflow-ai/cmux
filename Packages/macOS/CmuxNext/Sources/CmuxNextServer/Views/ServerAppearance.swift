import AppKit
import Observation
import SwiftUI

/// Colors of the server UI, resolved by the host view in its theme scope
/// (Ghostty-derived chrome tokens). No accent color: hover and selection
/// are grays, severities are the theme's attention, danger and success.
struct ServerColors: Equatable {
    var primary = Color(nsColor: .labelColor)
    var secondary = Color(nsColor: .secondaryLabelColor)
    var tertiary = Color(nsColor: .tertiaryLabelColor)
    var hover = Color(nsColor: .quaternaryLabelColor)
    var selection = Color(nsColor: .unemphasizedSelectedContentBackgroundColor)
    var separator = Color(nsColor: .separatorColor)
    var warning = Color(nsColor: .systemOrange)
    var critical = Color(nsColor: .systemRed)
    var ok = Color(nsColor: .systemGreen)
    /// Text drawn on a `primary` fill (the Approve button).
    var onPrimary = Color(nsColor: .windowBackgroundColor)

    /// A card or field fill: a faint wash of the text color, which reads on
    /// glass and on the opaque fallback alike.
    var fill: Color { primary.opacity(0.055) }

    func severity(_ severity: HealthSeverity?) -> Color {
        switch severity {
        case .critical: critical
        case .warning: warning
        case .info: secondary
        case nil: ok
        }
    }
}

@Observable
final class ServerAppearance {
    var colors = ServerColors()
}

extension EnvironmentValues {
    @Entry var serverColors = ServerColors()
    /// Border width multiplier: 0 under `appearance.borders = none`.
    @Entry var serverLineWidth: CGFloat = 1
}
