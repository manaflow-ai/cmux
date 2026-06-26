import SwiftUI

/// The floating "jump to live tail" pill shown when the user has scrolled
/// away from the bottom of the transcript.
public struct ChatScrollToBottomButton: View {
    private let action: () -> Void

    /// Creates the button.
    ///
    /// - Parameter action: Called on tap; the host scrolls to the bottom
    ///   and re-engages auto-follow.
    public init(action: @escaping () -> Void) {
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Image(systemName: "chevron.down")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 38, height: 38)
                .background(.thinMaterial, in: .circle)
                .overlay(Circle().strokeBorder(.separator.opacity(0.4), lineWidth: 0.5))
                .contentShape(Circle().inset(by: -3))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            String(
                localized: "chat.scroll_to_bottom.accessibility",
                defaultValue: "Scroll to latest message",
                bundle: .module
            )
        )
    }
}
