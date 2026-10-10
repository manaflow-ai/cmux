// The actions whose effect only the person may cause (cx-zk9t, chief decision on
// 13742): money, trust, and the irreversible loss of data outside the local layout.
// They are person-only (`ActionDescriptor.isPersonOnly`): the control socket, the CLI,
// MCP and pages are refused with the localized person-only reason, with no
// `confirm: true` escape. The keyboard, menu, palette and context-menu runs still ask
// their confirmation first. Local layout operations that agents use daily
// (closeWorkspace, tabGroup.close, workspaceGroup.closeWorkspaces, space.delete,
// remote.forget) stay scriptable with `confirm: true`.
nonisolated extension ActionCatalog {
    static let personOnlyEffectIDs: Set<ActionID> = [
        // Quit ends the running terminals and agents; End Everything also deletes every local workspace.
        "quitEndSessions", "quitEndEverything",
        // Cloud: money (resize) and irreversible deletion of a machine, a snapshot, a file or a rule.
        "cloudKillMachine", "palette.cloud.deleteSnapshot", "cloudFileRemove", "cloudFirewallDelete", "cloudResizeMachine",
        // A browser profile's data, and an account's stored credentials.
        "browserProfile.delete", "accounts.remove",
        // Installs cmux on another machine and runs it there: a trust grant.
        "remote.install",
        // Audit (cx-zk9t): the same effects without their dialog. A site's camera, microphone or
        // downloads grant; a site's, an extension's or the browsing history's data; a Cloud
        // machine's network opening, tunnel key, owner or restored state.
        "browser.prompt.allow", "browser.pageInfo.deleteSiteData", "browser.extension.remove",
        "history.clear", "palette.browserClearHistory",
        "cloudFirewallCreate", "cloudTunnelRotateKey", "palette.cloud.handoff", "palette.cloud.restore",
    ]
}
