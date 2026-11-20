public import SwiftUI

/// The panel's footer action: create a workspace without leaving the sidebar.
///
/// A full-width row rather than a small `+` glyph. The panel is often reached
/// by pointer, and a row-shaped target matches the rows above it, so the
/// gesture that picks a workspace is the same gesture that makes one.
public struct SidebarNewWorkspaceButton: View {
    /// The sidebar accent color.
    public let accent: Color
    /// Point size of the label.
    public let fontSize: CGFloat
    /// Creates a workspace.
    public let onCreate: () -> Void

    @State private var isHovering = false

    /// Creates the footer action.
    ///
    /// - Parameters:
    ///   - accent: The sidebar accent color.
    ///   - fontSize: Point size of the label.
    ///   - onCreate: Called to create a workspace.
    public init(
        accent: Color,
        fontSize: CGFloat = 11.5,
        onCreate: @escaping () -> Void
    ) {
        self.accent = accent
        self.fontSize = fontSize
        self.onCreate = onCreate
    }

    public var body: some View {
        Button(action: onCreate) {
            HStack(spacing: 6) {
                Image(systemName: "plus")
                    .font(.system(size: fontSize - 1, weight: .semibold))
                Text(String(
                    localized: "sidebar.newWorkspace",
                    defaultValue: "New workspace"
                ))
                .font(.system(size: fontSize, weight: .medium))
                Spacer(minLength: 0)
            }
            .foregroundStyle(isHovering ? AnyShapeStyle(accent) : AnyShapeStyle(.secondary))
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(isHovering ? 0.06 : 0))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .padding(.horizontal, 8)
        .accessibilityIdentifier("SidebarNewWorkspaceButton")
    }
}
