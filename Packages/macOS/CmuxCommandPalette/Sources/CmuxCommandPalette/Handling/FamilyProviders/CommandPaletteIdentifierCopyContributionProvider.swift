import Foundation

/// Builds the identifier-copy palette contribution slice (copy workspace / pane
/// / surface IDs, refs, and links). The provider owns the *structure* (command
/// identifiers, keywords, the `when` gates over the snapshot keys, and the order
/// in which the workspace and panel commands appear); the localized titles are
/// resolved app-side and handed in through ``Strings``, and the entity-aware
/// subtitles arrive as the same per-snapshot closures the legacy builder used.
///
/// The clipboard handlers stay app-side behind ``CommandPaletteActionHandling``
/// because they read live workspace/panel identity and write the pasteboard.
public struct CommandPaletteIdentifierCopyContributionProvider {
    /// App-resolved titles for the identifier-copy commands.
    public struct Strings: Sendable, Equatable {
        /// "Copy Workspace ID" title.
        public let copyWorkspaceID: String
        /// "Copy Workspace ID and Ref" title.
        public let copyWorkspaceIDAndRef: String
        /// "Copy Workspace Link" title.
        public let copyWorkspaceLink: String
        /// "Copy Pane ID" title.
        public let copyPaneID: String
        /// "Copy Pane Link" title.
        public let copyPaneLink: String
        /// "Copy Surface ID" title.
        public let copySurfaceID: String
        /// "Copy Surface Link" title.
        public let copySurfaceLink: String
        /// "Copy IDs" (workspace + pane + surface) title.
        public let copyIdentifiers: String

        /// Creates the resolved identifier-copy strings.
        public init(
            copyWorkspaceID: String,
            copyWorkspaceIDAndRef: String,
            copyWorkspaceLink: String,
            copyPaneID: String,
            copyPaneLink: String,
            copySurfaceID: String,
            copySurfaceLink: String,
            copyIdentifiers: String
        ) {
            self.copyWorkspaceID = copyWorkspaceID
            self.copyWorkspaceIDAndRef = copyWorkspaceIDAndRef
            self.copyWorkspaceLink = copyWorkspaceLink
            self.copyPaneID = copyPaneID
            self.copyPaneLink = copyPaneLink
            self.copySurfaceID = copySurfaceID
            self.copySurfaceLink = copySurfaceLink
            self.copyIdentifiers = copyIdentifiers
        }
    }

    /// Creates the provider. It is stateless; the catalog is baked into ``build``.
    public init() {}

    /// Assembles the identifier-copy contribution slice in its legacy order.
    ///
    /// - Parameters:
    ///   - strings: App-resolved command titles.
    ///   - workspaceSubtitle: Subtitle closure for the workspace commands.
    ///   - panelSubtitle: Subtitle closure for the pane/surface commands.
    public func build(
        strings: Strings,
        workspaceSubtitle: @escaping (CommandPaletteContextSnapshot) -> String,
        panelSubtitle: @escaping (CommandPaletteContextSnapshot) -> String
    ) -> [CommandPaletteCommandContribution] {
        func constant(_ value: String) -> (CommandPaletteContextSnapshot) -> String {
            { _ in value }
        }

        var contributions: [CommandPaletteCommandContribution] = []

        let workspaceCommands: [(id: String, title: String, keywords: [String])] = [
            (
                "palette.copyWorkspaceID",
                strings.copyWorkspaceID,
                ["copy", "workspace", "id", "identifier"]
            ),
            (
                "palette.copyWorkspaceIDAndRef",
                strings.copyWorkspaceIDAndRef,
                ["copy", "workspace", "id", "identifier", "ref", "reference"]
            ),
            (
                "palette.copyWorkspaceLink",
                strings.copyWorkspaceLink,
                ["copy", "workspace", "link", "url", "deeplink", "deep link"]
            ),
        ]
        contributions += workspaceCommands.map { command in
            CommandPaletteCommandContribution(
                commandId: command.id,
                title: constant(command.title),
                subtitle: workspaceSubtitle,
                keywords: command.keywords,
                when: { $0.bool(CommandPaletteContextKeys.hasWorkspace) }
            )
        }

        let panelCommands: [(id: String, title: String, keywords: [String], requiresPane: Bool)] = [
            (
                "palette.copyPaneID",
                strings.copyPaneID,
                ["copy", "pane", "split", "id", "identifier"],
                true
            ),
            (
                "palette.copyPaneLink",
                strings.copyPaneLink,
                ["copy", "pane", "split", "link", "url", "deeplink", "deep link"],
                true
            ),
            (
                "palette.copySurfaceID",
                strings.copySurfaceID,
                ["copy", "surface", "tab", "id", "identifier"],
                false
            ),
            (
                "palette.copySurfaceLink",
                strings.copySurfaceLink,
                ["copy", "surface", "tab", "link", "url", "deeplink", "deep link"],
                false
            ),
            (
                "palette.copyIdentifiers",
                strings.copyIdentifiers,
                ["copy", "ids", "identifiers", "workspace", "pane", "surface", "ref", "reference"],
                false
            ),
        ]
        contributions += panelCommands.map { command in
            CommandPaletteCommandContribution(
                commandId: command.id,
                title: constant(command.title),
                subtitle: panelSubtitle,
                keywords: command.keywords,
                when: {
                    command.requiresPane
                        ? $0.bool(CommandPaletteContextKeys.panelHasPane)
                        : $0.bool(CommandPaletteContextKeys.hasFocusedPanel)
                }
            )
        }

        return contributions
    }
}
