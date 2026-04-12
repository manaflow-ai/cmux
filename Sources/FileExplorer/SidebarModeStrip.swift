import SwiftUI

/// The sidebar's internal panel mode — controls which content the sidebar shows.
enum SidebarPanelMode: String {
    case workspaces
    case files
}

/// Horizontal icon strip at the top of the sidebar for switching between
/// workspace list and file explorer.
struct SidebarModeStrip: View {
    @Binding var mode: SidebarPanelMode

    private let height: CGFloat = 28
    private let iconSize: CGFloat = 13
    private let buttonSize: CGFloat = 24

    var body: some View {
        HStack(spacing: 2) {
            modeButton(
                systemName: "rectangle.stack",
                targetMode: .workspaces,
                tooltip: String(localized: "sidebar.mode.workspaces", defaultValue: "Workspaces")
            )
            modeButton(
                systemName: "folder",
                targetMode: .files,
                tooltip: String(localized: "sidebar.mode.files", defaultValue: "Files")
            )
            Spacer()
        }
        .padding(.horizontal, 10)
        .frame(height: height)
    }

    @ViewBuilder
    private func modeButton(systemName: String, targetMode: SidebarPanelMode, tooltip: String) -> some View {
        let isSelected = mode == targetMode
        Button {
            mode = targetMode
        } label: {
            Image(systemName: systemName)
                .font(.system(size: iconSize, weight: .medium))
                .foregroundColor(isSelected ? .accentColor : .secondary)
                .frame(width: buttonSize, height: buttonSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(tooltip)
        .accessibilityLabel(Text(tooltip))
    }
}
