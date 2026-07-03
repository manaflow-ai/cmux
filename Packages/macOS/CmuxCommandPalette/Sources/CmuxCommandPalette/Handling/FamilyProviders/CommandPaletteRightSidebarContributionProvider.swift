public import CmuxSidebar

/// Builds the right-sidebar palette contribution slices: the mode-switch
/// commands (Files / Find / Vault / Feed / Dock) and the open-as-pane commands.
/// The provider owns the *structure* (the stable `RightSidebarMode` →
/// command-identifier mapping, search keywords, ordinal order, and which modes
/// can open as a pane); the localized command titles and subtitles are resolved
/// app-side and handed in through the per-mode descriptors.
///
/// The mode → command-identifier mapping lives here as the single source of
/// truth so the app's shortcut-hint resolver and the palette builder agree. The
/// runnable handlers (focus the sidebar / open a tool pane) stay app-side behind
/// ``CommandPaletteActionHandling`` because they drive live window and
/// file-explorer state, and the command titles depend on app-owned
/// `KeyboardShortcutSettings` labels.
public struct CommandPaletteRightSidebarContributionProvider {
    /// One mode-switch command: the mode plus its app-resolved title.
    public struct ModeCommand: Sendable, Equatable {
        /// The right-sidebar mode the command switches to.
        public let mode: RightSidebarMode
        /// App-resolved display title (the mode's shortcut-action label, falling
        /// back to the mode label).
        public let title: String

        /// Creates a mode-switch command descriptor.
        public init(mode: RightSidebarMode, title: String) {
            self.mode = mode
            self.title = title
        }
    }

    /// One open-as-pane command: the mode plus its app-resolved title and the
    /// app-resolved lowercased mode label used as a search keyword.
    public struct ToolPaneCommand: Sendable, Equatable {
        /// The right-sidebar mode the pane hosts.
        public let mode: RightSidebarMode
        /// App-resolved display title (e.g. "Open Files as Pane").
        public let title: String
        /// App-resolved lowercased mode label, added to the search keywords
        /// exactly as the legacy builder did (`mode.label.lowercased()`).
        public let labelKeyword: String

        /// Creates an open-as-pane command descriptor.
        public init(mode: RightSidebarMode, title: String, labelKeyword: String) {
            self.mode = mode
            self.title = title
            self.labelKeyword = labelKeyword
        }
    }

    /// Creates the provider. It is stateless; the catalogs are supplied per call.
    public init() {}

    /// The stable palette command identifier for switching to `mode`.
    public func modeCommandID(_ mode: RightSidebarMode) -> String {
        switch mode {
        case .files:
            return "palette.showRightSidebarFiles"
        case .find:
            return "palette.showRightSidebarFind"
        case .sessions:
            return "palette.showRightSidebarSessions"
        case .feed:
            return "palette.showRightSidebarFeed"
        case .dock:
            return "palette.showRightSidebarDock"
        case .customSidebar:
            return "palette.showRightSidebarFiles"
        }
    }

    /// The stable palette command identifier for opening `mode` as a pane, or
    /// `nil` for modes that cannot open as a pane.
    public func toolPaneCommandID(_ mode: RightSidebarMode) -> String? {
        switch mode {
        case .files:
            return "palette.openFilesPane"
        case .find:
            return "palette.openFindPane"
        case .sessions:
            return "palette.openVaultPane"
        case .feed, .dock:
            return nil
        }
    }

    /// Assembles the mode-switch contribution slice in its legacy order.
    ///
    /// - Parameters:
    ///   - commands: App-resolved mode commands, in display order.
    ///   - subtitle: Shared "Right Sidebar" subtitle for every command.
    public func buildModeContributions(
        commands: [ModeCommand],
        subtitle: String
    ) -> [CommandPaletteCommandContribution] {
        commands.map { command in
            CommandPaletteCommandContribution(
                commandId: modeCommandID(command.mode),
                title: { _ in command.title },
                subtitle: { _ in subtitle },
                keywords: ["right", "sidebar", "show", "switch", "focus", command.mode.rawValue]
            )
        }
    }

    /// Assembles the open-as-pane contribution slice in its legacy order.
    ///
    /// - Parameters:
    ///   - commands: App-resolved pane commands, in display order. Commands
    ///     whose mode cannot open as a pane are dropped.
    ///   - subtitle: Shared "Pane" subtitle for every command.
    public func buildToolPaneContributions(
        commands: [ToolPaneCommand],
        subtitle: String
    ) -> [CommandPaletteCommandContribution] {
        commands.compactMap { command in
            guard let commandId = toolPaneCommandID(command.mode) else { return nil }
            return CommandPaletteCommandContribution(
                commandId: commandId,
                title: { _ in command.title },
                subtitle: { _ in subtitle },
                keywords: ["open", "pane", "tool", "right", "sidebar", command.mode.rawValue, command.labelKeyword]
            )
        }
    }
}
