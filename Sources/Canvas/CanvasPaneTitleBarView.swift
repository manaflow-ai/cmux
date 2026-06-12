import SwiftUI

/// The SwiftUI chrome strip at the top of a canvas pane: kind icon, title,
/// and a close button. The strip is also the pane's move-drag handle (drag
/// handling lives in `CanvasPaneView`; plain SwiftUI content here does not
/// consume mouse-down events).
struct CanvasPaneTitleBarView: View {
    let title: String
    let iconSystemName: String?
    let isFocused: Bool
    let onClose: () -> Void

    @State private var isHoveringClose = false

    static let height: CGFloat = 28

    var body: some View {
        HStack(spacing: 6) {
            if let iconSystemName {
                Image(systemName: iconSystemName)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(isFocused ? .primary : .secondary)
            }
            Text(title)
                .font(.system(size: 12, weight: isFocused ? .semibold : .regular))
                .foregroundStyle(isFocused ? .primary : .secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(isHoveringClose ? .primary : .secondary)
                    .frame(width: 18, height: 18)
                    .background(
                        Circle().fill(isHoveringClose ? Color.primary.opacity(0.12) : .clear)
                    )
            }
            .buttonStyle(.plain)
            .onHover { isHoveringClose = $0 }
            .help(String(localized: "canvas.pane.close.help", defaultValue: "Close Pane"))
            .accessibilityLabel(String(localized: "canvas.pane.close.help", defaultValue: "Close Pane"))
        }
        .padding(.horizontal, 10)
        .frame(height: Self.height)
        .contentShape(Rectangle())
    }
}
