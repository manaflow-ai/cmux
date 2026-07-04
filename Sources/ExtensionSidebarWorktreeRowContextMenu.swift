import SwiftUI

/// Attaches worktree management commands only to cmux-managed worktree rows.
struct ExtensionSidebarWorktreeRowContextMenu: ViewModifier {
    let worktree: CmuxExtensionWorktreeIdentity?
    let onOpenTerminal: (String) -> Void
    let onRemove: (String) -> Void

    @ViewBuilder
    func body(content: Content) -> some View {
        if let worktree {
            content.contextMenu {
                Button(String(
                    localized: "sidebar.extension.openTerminalInside",
                    defaultValue: "Open Terminal Inside"
                )) {
                    onOpenTerminal(worktree.worktreePath)
                }
                Button(
                    String(localized: "sidebar.extension.removeWorktree", defaultValue: "Remove Worktree\u{2026}"),
                    role: .destructive
                ) {
                    onRemove(worktree.worktreePath)
                }
            }
        } else {
            content
        }
    }
}
