import SwiftUI

struct ExtensionSidebarWorktreeHeaderControls: View {
    let worktree: CmuxExtensionWorktreeIdentity
    let sectionId: String
    let onOpenTerminal: (String) -> Void
    let onRemove: (String) -> Void

    var body: some View {
        Button {
            onOpenTerminal(worktree.worktreePath)
        } label: {
            Image(systemName: "terminal")
                .font(.system(size: 11, weight: .regular))
                .frame(width: 18, height: 18)
        }
        .buttonStyle(.plain)
        .safeHelp(openTerminalHelp)
        .accessibilityLabel(Text(openTerminalHelp))
        .accessibilityIdentifier("ExtensionSidebarOpenWorktreeTerminalButton.\(sectionId)")

        Button {
            onRemove(worktree.worktreePath)
        } label: {
            Image(systemName: "trash")
                .font(.system(size: 11, weight: .regular))
                .frame(width: 18, height: 18)
        }
        .buttonStyle(.plain)
        .safeHelp(removeHelp)
        .accessibilityLabel(Text(removeHelp))
        .accessibilityIdentifier("ExtensionSidebarRemoveWorktreeButton.\(sectionId)")
    }

    private var openTerminalHelp: String {
        String(
            localized: "sidebar.extension.openTerminalInside.help",
            defaultValue: "Open terminal inside this worktree"
        )
    }

    private var removeHelp: String {
        String(
            localized: "sidebar.extension.removeWorktree.help",
            defaultValue: "Remove this worktree"
        )
    }
}
