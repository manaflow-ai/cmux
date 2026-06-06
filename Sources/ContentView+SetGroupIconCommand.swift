import AppKit
import SwiftUI

extension ContentView {
    /// Contributes the "Set Group Icon" command-palette entry.
    ///
    /// The command is offered whenever the focused workspace belongs to a group (as the group's
    /// anchor or as one of its children). Running it opens the icon picker inside the palette, so it
    /// keeps the palette open (`dismissOnRun: false`); see `commandPaletteSetGroupIconView`.
    func appendSetGroupIconCommandContribution(
        to contributions: inout [CommandPaletteCommandContribution]
    ) {
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.setGroupIcon",
                title: { _ in
                    String(localized: "command.setGroupIcon.title", defaultValue: "Set Group Icon…")
                },
                subtitle: { _ in
                    String(localized: "command.setGroupIcon.subtitle", defaultValue: "Workspace Group")
                },
                keywords: ["group", "icon", "emoji", "symbol", "workspace", "set", "folder"],
                dismissOnRun: false,
                when: { $0.bool(CommandPaletteContextKeys.workspaceInGroup) }
            )
        )
    }
}
