import SwiftUI

/// Preview shown during tab drag operations
struct TabDragPreview: View {
    let tab: SurfaceItem
    let appearance: WorkspaceLayoutConfiguration.Appearance

    var body: some View {
        HStack(spacing: TabBarMetrics.contentSpacing) {
            if let iconName = tab.icon {
                Image(systemName: iconName)
                    .font(.system(size: TabBarMetrics.iconSize))
                    .foregroundStyle(TabBarColors.activeText(for: appearance))
            }

            Text(tab.title)
                .font(.system(size: appearance.tabTitleFontSize))
                .lineLimit(1)
                .foregroundStyle(TabBarColors.activeText(for: appearance))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: TabBarMetrics.tabCornerRadius, style: .continuous)
                .fill(TabBarColors.activeTabBackground(for: appearance))
                .shadow(color: .black.opacity(0.2), radius: 4, y: 2)
        )
        .opacity(0.9)
    }
}
