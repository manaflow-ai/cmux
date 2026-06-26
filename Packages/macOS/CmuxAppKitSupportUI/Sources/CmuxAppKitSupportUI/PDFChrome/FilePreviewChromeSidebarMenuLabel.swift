public import SwiftUI

/// The sidebar-toggle menu label in the file-preview PDF chrome: a sidebar icon
/// plus a downward chevron inside a hover-highlighted capsule.
///
/// Tracks its own hover state and shifts foreground tint and capsule fill on hover.
public struct FilePreviewChromeSidebarMenuLabel: View {
    @State private var isHovered = false

    /// Creates a sidebar menu label.
    public init() {}

    public var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "sidebar.left")
            Image(systemName: "chevron.down")
                .font(.system(size: 11, weight: .semibold))
        }
        .font(.system(size: 16, weight: .semibold))
        .foregroundStyle(isHovered ? Color.primary : Color.secondary)
        .frame(width: 68, height: 34)
        .background {
            Capsule()
                .fill(Color.white.opacity(isHovered ? 0.14 : 0))
        }
        .contentShape(Capsule())
        .onHover { hovering in
            isHovered = hovering
        }
    }
}
