#if canImport(AppKit)
// Spaces off (`sidebar.showSpaces` false, the default since https://github.com/manaflow-ai/cmux/issues/48355):
// every action that makes, shows, switches, reorders or moves into a space leaves the palette, menus, context menus
// and shortcuts, and `action.run` (CLI, MCP, socket) refuses it with the reason. Each window keeps the space it
// shows, so its workspaces, groups and pins stay as they were; New Window and tear-off keep their own view.
// The theme rows stay: Settings edits the shown space's theme through them. Show Spaces and Hide Spaces are space
// actions too: the sidebar footer's menu, the palette and the keys offered Show Spaces exactly while Spaces was off,
// so it named spaces after Spaces went away. The way back on is Settings' switch (Settings search finds it) or
// `sidebar.showSpaces` in cmux.json.
extension ActionRegistry {
    /// Turns the space actions off while `enabled` returns false, composed with the reasons already installed.
    public func installSpacesGate(reason: String, enabled: @escaping @MainActor () -> Bool) {
        let previous = settingOffReason
        settingOffReason = { id in
            if isSpaceAction(id), !enabled() { return reason }
            return previous(id)
        }
    }
}
#endif

/// The actions Spaces off turns off: every `space.*` action but the theme rows, and the actions elsewhere that
/// create a space or move something into another one.
private nonisolated func isSpaceAction(_ id: ActionID) -> Bool {
    let raw = id.rawValue
    if raw.hasPrefix("space.") { return raw != "space.setTheme" && raw != "space.clearTheme" }
    return [
        "workspace.moveToSpace", "workspace.unpinFromSpace", "workspace.duplicateToSpace",
        "workspaceGroup.moveToSpace", "tab.moveToSpace", "browser.link.openInNewSpace",
        "browserProfile.setSpaceDefault", "browserProfile.clearSpaceDefault", "sidebar.section.toggleSpaceScope",
        "sidebar.spaces.show", "sidebar.spaces.hide",
    ].contains(raw)
}
