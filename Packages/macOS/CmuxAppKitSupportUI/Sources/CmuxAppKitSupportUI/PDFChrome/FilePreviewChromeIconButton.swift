public import SwiftUI

/// A square, SF Symbol toolbar button used in the file-preview PDF chrome.
///
/// Tracks its own hover state and renders through ``FilePreviewChromeHoverButtonStyle``
/// so the symbol tints and the rounded backing capsule respond to hover and press.
public struct FilePreviewChromeIconButton: View {
    let systemName: String
    let label: String
    let action: () -> Void

    @State private var isHovered = false

    /// Creates a chrome icon button.
    /// - Parameters:
    ///   - systemName: The SF Symbol name rendered as the button's image.
    ///   - label: The accessibility label and help (tooltip) text.
    ///   - action: The closure invoked when the button is pressed.
    public init(systemName: String, label: String, action: @escaping () -> Void) {
        self.systemName = systemName
        self.label = label
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 16, weight: .semibold))
                .frame(width: 42, height: 40)
        }
        .buttonStyle(FilePreviewChromeHoverButtonStyle(isHovered: isHovered))
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovered = hovering
        }
        .accessibilityLabel(label)
        .help(label)
    }
}
