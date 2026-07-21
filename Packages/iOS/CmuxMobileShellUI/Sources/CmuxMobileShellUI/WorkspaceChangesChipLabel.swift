import CmuxMobileChanges
import CmuxMobileShell
import SwiftUI

/// The compact changes capsule shared by workspace-list and toolbar entry points.
struct WorkspaceChangesChipLabel: View {
    let chip: MobileWorkspaceChangesChip
    let workspaceID: String
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let theme = ChangesTheme(colorScheme: colorScheme)
        let text = chipText
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
        .font(.caption2.weight(.semibold))
        .monospacedDigit()
        .lineLimit(1)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(Capsule().fill(Color.secondary.opacity(0.12)))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel(for: text))
        .accessibilityIdentifier("MobileChangesChip-\(workspaceID)")
    }

    private var chipText: WorkspaceChangesChipText {
        WorkspaceChangesChipTextPolicy().text(
            filesChanged: chip.filesChanged,
            additions: chip.additions,
            deletions: chip.deletions
        )
    }

    private func accessibilityLabel(for text: WorkspaceChangesChipText) -> String {
        guard text.secondary != nil else { return text.combined }
        return String(
            format: String(
                localized: "workspace.changes.chip.accessibility",
                defaultValue: "%1$lld additions, %2$lld deletions",
                bundle: .module
            ),
            chip.additions,
            chip.deletions
        )
    }
}
