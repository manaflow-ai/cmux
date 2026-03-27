import SwiftUI
import Foundation
import AppKit

// MARK: - WorkspaceTabBarView

/// Horizontal tab bar rendered above the BonsplitView when a workspace has 2+ tabs.
/// Auto-hides when only one workspace tab exists.
struct WorkspaceTabBarView: View {
    @ObservedObject var workspace: Workspace

    var body: some View {
        if workspace.workspaceTabs.count > 1 {
            HStack(spacing: 0) {
                tabItems
                newTabButton
                Spacer()
            }
            .frame(height: 28)
            .background(Color(nsColor: GhosttyBackgroundTheme.currentColor()).opacity(0.85))
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(Color.primary.opacity(0.08))
                    .frame(height: 1)
            }
        }
    }

    // MARK: - Tab Items

    private var tabItems: some View {
        ForEach(Array(workspace.workspaceTabs.enumerated()), id: \.element.id) { index, tab in
            WorkspaceTabItemView(
                title: workspaceTabTitle(for: tab),
                isSelected: index == workspace.selectedWorkspaceTabIndex,
                onSelect: { workspace.selectWorkspaceTab(at: index) },
                onClose: { workspace.closeWorkspaceTab(at: index) }
            )
        }
    }

    // MARK: - New Tab Button

    private var newTabButton: some View {
        let tooltip = KeyboardShortcutSettings.Action.newWorkspaceTab.tooltip(
            String(localized: "workspaceTabBar.newTab.tooltip", defaultValue: "New Workspace Tab")
        )
        return Button(action: { workspace.createWorkspaceTab() }) {
            Image(systemName: "plus")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(tooltip)
    }

    // MARK: - Title Derivation

    /// Derive a display title for a workspace tab.
    /// Uses the first terminal panel's current directory basename, falling back to "New Tab".
    private func workspaceTabTitle(for tab: WorkspaceTab) -> String {
        // Use custom title if set
        if let customTitle = tab.customTitle, !customTitle.isEmpty {
            return customTitle
        }
        // Try to find the first panel directory in this tab
        for panelId in tab.panels.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
            if let directory = tab.panelDirectories[panelId], !directory.isEmpty {
                let basename = (directory as NSString).lastPathComponent
                if !basename.isEmpty {
                    return basename
                }
            }
        }

        // Try panel titles
        for panelId in tab.panels.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
            if let title = tab.panelTitles[panelId]?.trimmingCharacters(in: .whitespacesAndNewlines),
               !title.isEmpty {
                return title
            }
        }

        return "New Tab"
    }
}

// MARK: - WorkspaceTabItemView

/// A single tab item in the workspace tab bar.
struct WorkspaceTabItemView: View {
    let title: String
    let isSelected: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 4) {
            Text(title)
                .font(.system(size: 12, weight: isSelected ? .medium : .regular))
                .foregroundStyle(isSelected ? .primary : .secondary)
                .lineLimit(1)
                .truncationMode(.tail)

            closeButton
                .opacity(isHovering || isSelected ? 1 : 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .frame(height: 28)
        .background(tabBackground)
        .contentShape(Rectangle())
        .onTapGesture { onSelect() }
        .onHover { hovering in
            isHovering = hovering
        }
    }

    // MARK: - Close Button

    private var closeButton: some View {
        let tooltip = KeyboardShortcutSettings.Action.closeWorkspaceTab.tooltip(
            String(localized: "workspaceTabBar.closeTab.tooltip", defaultValue: "Close Workspace Tab")
        )
        return Button(action: onClose) {
            Image(systemName: "xmark")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: 16, height: 16)
                .background(
                    Circle()
                        .fill(Color.primary.opacity(isHovering ? 0.1 : 0))
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(tooltip)
    }

    // MARK: - Background

    @ViewBuilder
    private var tabBackground: some View {
        if isSelected {
            RoundedRectangle(cornerRadius: 5)
                .fill(Color.primary.opacity(0.1))
                .padding(.vertical, 3)
                .padding(.horizontal, 2)
        } else if isHovering {
            RoundedRectangle(cornerRadius: 5)
                .fill(Color.primary.opacity(0.05))
                .padding(.vertical, 3)
                .padding(.horizontal, 2)
        }
    }
}
