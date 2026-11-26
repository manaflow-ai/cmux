import CmuxMobileChanges
import CmuxMobileShell
import SwiftUI

/// The compact changes capsule shared by workspace-list and toolbar entry points.
struct WorkspaceChangesChipLabel: View {
    let chip: MobileWorkspaceChangesChip
    let workspaceID: String
    var showsCapsuleBackground = true
    /// Stacks +N over −M for width-constrained hosts (the toolbar button).
    var stacksVertically = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        counts
            .font(.caption2.weight(.semibold))
        .monospacedDigit()
        .lineLimit(1)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background {
            if showsCapsuleBackground {
                Capsule().fill(Color.secondary.opacity(0.12))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityIdentifier("MobileChangesChip-\(workspaceID)")
    }

    @ViewBuilder
    private var counts: some View {
        let theme = ChangesTheme(colorScheme: colorScheme)
        let text = chipText
        if stacksVertically, let secondary = text.secondary {
            VStack(spacing: 0) {
                Text(text.primary)
                    .foregroundStyle(theme.addedStatus)
                Text(secondary)
                    .foregroundStyle(theme.deletedStatus)
            }
        } else {
            HStack(spacing: 3) {
                if let secondary = text.secondary {
                    Text(text.primary)
                        .foregroundStyle(theme.addedStatus)
                    Text(secondary)
                        .foregroundStyle(theme.deletedStatus)
                } else {
                    Text(text.primary)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var chipText: WorkspaceChangesChipText {
        WorkspaceChangesChipTextPolicy().text(
            filesChanged: chip.filesChanged,
            additions: chip.additions,
            deletions: chip.deletions
        )
    }

    private var accessibilityLabel: String {
        let fileCount = WorkspaceChangesChipTextPolicy().fileCountText(chip.filesChanged)
        return String(
            format: String(
                localized: "workspace.changes.chip.accessibility",
                defaultValue: "Changes: %1$@, +%2$lld, −%3$lld",
                bundle: .module
            ),
            fileCount,
            chip.additions,
            chip.deletions
        )
    }
}
