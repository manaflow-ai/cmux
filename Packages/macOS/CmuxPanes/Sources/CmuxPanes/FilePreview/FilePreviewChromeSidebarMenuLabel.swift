import SwiftUI

/// Hover-highlighting capsule label for the liquid-glass PDF sidebar menu
/// (sidebar glyph plus a disclosure chevron).
struct FilePreviewChromeSidebarMenuLabel: View {
    @State private var isHovered = false

    var body: some View {
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
