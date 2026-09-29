import CmuxNextDesign
import SwiftUI

/// Placeholder sidebar: a header and the workspace list with gray selection.
struct SidebarView: View {
    let model: ShellModel

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(Strings.sidebarTitle)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color(nsColor: Palette.textSecondary))
                .padding(.horizontal, 10)
                .padding(.bottom, 4)
            ForEach(model.workspaces) { workspace in
                ChromeRow(
                    title: workspace.title,
                    isSelected: workspace.id == model.selectedWorkspaceID
                ) {
                    model.selectedWorkspaceID = workspace.id
                }
            }
            Spacer(minLength: 0)
        }
        // Clear the traffic lights that sit over the sidebar's top edge.
        .padding(.top, Metrics.tabStripHeight)
        .padding(.horizontal, 6)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// Placeholder tab strip. Chrome-style shrinking, previews, and open/close
/// animation belong to the tab-strip agent (AppKit, per shell.md).
struct TabStripView: View {
    let model: ShellModel

    var body: some View {
        HStack(spacing: 4) {
            ForEach(model.tabs) { tab in
                ChromeRow(title: tab.title, isSelected: tab.id == model.selectedTabID) {
                    model.selectedTabID = tab.id
                }
                .frame(maxWidth: 200)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Row or tab with gray hover and selection. No accent color.
struct ChromeRow: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: isSelected ? .medium : .regular))
                .foregroundStyle(Color(nsColor: isSelected ? Palette.textPrimary : Palette.textSecondary))
                .lineLimit(1)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: Metrics.itemCornerRadius, style: .continuous)
                        .fill(Color(nsColor: fill))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .onHover { isHovered = $0 }
    }

    private var fill: NSColor {
        if isSelected { return Palette.selectionFill }
        if isHovered { return Palette.hoverFill }
        return .clear
    }
}
