#if os(iOS)
import CmuxMobileShell
import SwiftUI

/// The workspace-detail toolbar entry for the Changes sheet. With reviewable
/// changes it shows the same green/red counts as the workspace-list chip;
/// with a clean tree it falls back to the +/- glyph so the entry stays
/// discoverable whenever the host supports changes.
struct WorkspaceChangesToolbarButton: View {
    let chip: MobileWorkspaceChangesChip?
    let workspaceID: String
    var compact = false
    let action: @MainActor () -> Void

    var body: some View {
        Button(action: action) {
            if let chip, chip.filesChanged > 0, !compact {
                WorkspaceChangesChipLabel(
                    chip: chip,
                    workspaceID: workspaceID,
                    showsCapsuleBackground: false,
                    stacksVertically: true
                )
                .frame(minWidth: 30, minHeight: 30)
            } else {
                Label(changesTitle, systemImage: "plus.forwardslash.minus")
                .labelStyle(.iconOnly)
                .frame(width: 30, height: 30)
                .accessibilityLabel(changesTitle)
            }
        }
        .accessibilityIdentifier("MobileChangesButton")
    }

    private var changesTitle: String {
        String(
            localized: "workspace.changes.title",
            defaultValue: "Changes",
            bundle: .module
        )
    }
}
#endif
