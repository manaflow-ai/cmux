import AppKit
import CmuxCommandPalette
import CmuxPanes

extension ContentView {
    func paneSizingContributions(
        subtitle: @escaping (CommandPaletteContextSnapshot) -> String
    ) -> [CommandPaletteCommandContribution] {
        var contributions: [CommandPaletteCommandContribution] = []
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.equalizeSplits",
                title: { _ in String(localized: "command.equalizeSplits.title", defaultValue: "Equalize Splits") },
                subtitle: subtitle,
                keywords: ["split", "equalize", "balance", "divider", "layout"],
                when: { $0.bool(CommandPaletteContextKeys.workspaceHasSplits) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.newPaneAutoLayout",
                title: { _ in String(localized: "command.newPaneAutoLayout.title", defaultValue: "New Pane (Auto Layout)") },
                subtitle: subtitle,
                keywords: ["pane", "new", "split", "auto", "layout", "tile", "zellij", "grid"],
                when: { $0.bool(CommandPaletteContextKeys.panelIsTerminal) }
            )
        )
        for (commandId, action, directionKeyword) in [
            ("palette.resizePaneLeft", KeyboardShortcutSettings.Action.resizePaneLeft, "left"),
            ("palette.resizePaneRight", .resizePaneRight, "right"),
            ("palette.resizePaneUp", .resizePaneUp, "up"),
            ("palette.resizePaneDown", .resizePaneDown, "down"),
        ] {
            contributions.append(
                CommandPaletteCommandContribution(
                    commandId: commandId,
                    title: { _ in action.label },
                    subtitle: subtitle,
                    keywords: ["split", "pane", "resize", "divider", directionKeyword],
                    when: { $0.bool(CommandPaletteContextKeys.workspaceHasSplits) }
                )
            )
        }

        return contributions
    }

    func registerPaneResizeHandlers(
        _ registry: inout CommandPaletteHandlerRegistry,
        preferredWindow: @escaping () -> NSWindow?
    ) {
        registry.register(commandId: "palette.newPaneAutoLayout") {
            if AppDelegate.shared?.performAutoLayoutPaneShortcut(preferredWindow: preferredWindow()) != true {
                NSSound.beep()
            }
        }
        for (commandId, direction) in [
            ("palette.resizePaneLeft", ResizeDirection.left),
            ("palette.resizePaneRight", .right),
            ("palette.resizePaneUp", .up),
            ("palette.resizePaneDown", .down),
        ] {
            registry.register(commandId: commandId) {
                if AppDelegate.shared?.performResizePaneShortcut(
                    direction: direction,
                    preferredWindow: preferredWindow()
                ) != true {
                    NSSound.beep()
                }
            }
        }

    }
}
