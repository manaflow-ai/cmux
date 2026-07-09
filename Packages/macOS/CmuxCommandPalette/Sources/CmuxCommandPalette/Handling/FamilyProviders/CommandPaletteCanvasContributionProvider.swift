import Foundation

/// Builds the canvas-layout palette contribution slice (toggle layout, reveal
/// focused pane, overview, zoom, tidy, align, equalize, distribute). The
/// provider owns the *structure* (command identifiers, keywords, ordinal order,
/// and the `when` gates over the ``CommandPaletteContextKeys/hasWorkspace`` and
/// ``CommandPaletteContextKeys/workspaceCanvasLayout`` snapshot keys); the
/// localized command titles and the shared "Canvas" subtitle are resolved
/// app-side and handed in through ``Command`` descriptors.
///
/// The runnable handlers route through the app's `CanvasActionExecutor` (the
/// same path as shortcuts, the View menu, and the `canvas.*` socket verbs) and
/// stay app-side behind ``CommandPaletteActionHandling`` because they touch
/// app-owned live workspace state.
public struct CommandPaletteCanvasContributionProvider {
    /// One canvas command, with its app-resolved title and the structural
    /// metadata the provider needs to build the contribution.
    public struct Command: Sendable, Equatable {
        /// Stable command identifier (e.g. `palette.canvas.zoomIn`).
        public let commandId: String
        /// App-resolved display title (the canvas action's label).
        public let title: String
        /// Search keywords for the command.
        public let keywords: [String]
        /// Whether the command is offered even when the selected workspace is
        /// not in canvas layout. Only the layout-mode toggle sets this; every
        /// other canvas command is canvas-only.
        public let alwaysAvailable: Bool

        /// Creates a canvas command descriptor.
        public init(commandId: String, title: String, keywords: [String], alwaysAvailable: Bool) {
            self.commandId = commandId
            self.title = title
            self.keywords = keywords
            self.alwaysAvailable = alwaysAvailable
        }
    }

    /// Creates the provider. It is stateless; the catalog is supplied per call.
    public init() {}

    /// Assembles the canvas contribution slice in its legacy order.
    ///
    /// - Parameters:
    ///   - commands: App-resolved canvas commands, in display order.
    ///   - subtitle: Shared "Canvas" subtitle for every command.
    public func build(commands: [Command], subtitle: String) -> [CommandPaletteCommandContribution] {
        commands.map { command in
            CommandPaletteCommandContribution(
                commandId: command.commandId,
                title: { _ in command.title },
                subtitle: { _ in subtitle },
                keywords: command.keywords,
                when: { snapshot in
                    guard snapshot.bool(CommandPaletteContextKeys.hasWorkspace) else { return false }
                    // The mode toggle is always offered; everything else is
                    // canvas-only.
                    return command.alwaysAvailable
                        || snapshot.bool(CommandPaletteContextKeys.workspaceCanvasLayout)
                }
            )
        }
    }
}
