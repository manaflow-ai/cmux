public import SwiftUI

/// A plain icon button for panel headers: a tappable ``PanelHeaderIconGlyph``
/// with a tooltip and accessibility label.
///
/// Shared panel chrome; lives in `CmuxPanes` beside ``Panel``.
public struct PanelHeaderIconButton: View {
    private let systemName: String
    private let label: String
    private let isDisabled: Bool
    private let action: () -> Void

    /// Create a header icon button.
    /// - Parameters:
    ///   - systemName: SF Symbol drawn in the button.
    ///   - label: Tooltip and accessibility label.
    ///   - isDisabled: Whether the button is disabled.
    ///   - action: Invoked on tap.
    public init(
        systemName: String,
        label: String,
        isDisabled: Bool = false,
        action: @escaping () -> Void
    ) {
        self.systemName = systemName
        self.label = label
        self.isDisabled = isDisabled
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            PanelHeaderIconGlyph(systemName: systemName)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .disabled(isDisabled)
        .help(label)
        .accessibilityLabel(label)
    }
}
