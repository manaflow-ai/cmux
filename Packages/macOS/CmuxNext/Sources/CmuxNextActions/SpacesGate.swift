/// Spaces off (`sidebar.showSpaces` false, the default since https://github.com/manaflow-ai/cmux/issues/48355):
/// every action that makes, shows, switches, reorders or moves into a space leaves the palette, menus,
/// context menus and shortcuts, and `action.run` (CLI, MCP, socket) refuses it with the reason. Each
/// window keeps the space it shows, so its workspaces, groups and pins stay as they were; the other
/// spaces and their workspaces stay in the daemon, untouched, for when Spaces is turned back on.
/// The theme rows stay: Settings edits the shown space's theme through them.
public enum SpacesGate {
    /// The actions Spaces off turns off.
    public nonisolated static func isSpaceAction(_ id: ActionID) -> Bool {
        let raw = id.rawValue
        if raw.hasPrefix("space.") { return raw != "space.setTheme" && raw != "space.clearTheme" }
        return spaceMoves.contains(raw)
    }

    /// Actions outside `space.*` that create a space or move something into another one.
    nonisolated static let spaceMoves: Set<String> = [
        "workspace.moveToSpace", "workspace.unpinFromSpace", "workspace.duplicateToSpace",
        "workspaceGroup.moveToSpace", "tab.moveToSpace", "browser.link.openInNewSpace",
        "browserProfile.setSpaceDefault", "browserProfile.clearSpaceDefault", "sidebar.section.toggleSpaceScope",
    ]
}

extension ActionRegistry {
    /// Turns the space actions off while `enabled` returns false, composed with the reasons already installed.
    public func installSpacesGate(reason: String, enabled: @escaping @MainActor () -> Bool) {
        let previous = settingOffReason
        settingOffReason = { id in
            if SpacesGate.isSpaceAction(id), !enabled() { return reason }
            return previous(id)
        }
    }
}
