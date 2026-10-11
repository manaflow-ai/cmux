public import SwiftUI

/// The floating "Jump to Bottom" control drawn by a host of
/// ``JumpToBottomAffordance``: a terminal pane today, an agent chat
/// transcript later. The host positions it and decides when it shows.
public struct JumpToBottomPill: View {
    /// The pill's label, also used for its tooltip and accessibility label.
    public static var title: String {
        String(
            localized: "jumpToBottom.title",
            defaultValue: "Jump to Bottom",
            bundle: .module
        )
    }

    private let hasNewContentBelow: Bool
    private let accent: Color
    private let action: () -> Void

    /// - Parameters:
    ///   - hasNewContentBelow: Draws an accent dot when content arrived below
    ///     the viewport since it left the bottom.
    ///   - accent: The cmux accent for the arrow and dot.
    ///   - action: Scrolls the host to the bottom.
    public init(hasNewContentBelow: Bool, accent: Color, action: @escaping () -> Void) {
        self.hasNewContentBelow = hasNewContentBelow
        self.accent = accent
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: "arrow.down")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(accent)
                Text(Self.title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if hasNewContentBelow {
                    Circle()
                        .fill(accent)
                        .frame(width: 6, height: 6)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
            .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .help(Self.title)
        .accessibilityLabel(Self.title)
        .accessibilityIdentifier("JumpToBottomPill")
    }
}
