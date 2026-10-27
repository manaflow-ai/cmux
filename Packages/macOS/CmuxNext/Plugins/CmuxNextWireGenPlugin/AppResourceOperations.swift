extension CmuxNextWireGenPlugin {
    /// The `cmux.protocol/2` operations the macOS app calls, the only ones CmuxNextIPC gets typed
    /// requests for (p05-ipc.md, "Build time": generated Swift is limited to the app's methods, in
    /// per-family files). No operation in resource-operations-v2.json carries `clients` yet, so the
    /// list is kept here, where the plugin also derives the per-family output files from it. Taken
    /// from the operations CmuxNext's sources send by name (the Q11 census of tasks 045 and 047);
    /// add an operation here before a call site uses its generated request. CmuxNextWireGen refuses
    /// a name the catalog does not declare, or one whose `clients` leave out `macos`.
    static let appResourceOperations: [String] = [
        "agent.message.send",
        "browser.devices.list", "browser.tab.emulate", "browser.tab.emulate.clear",
        "chief.engine.get", "chief.engine.set", "chief.profile.avatar.get", "chief.profile.avatar.set",
        "chief.profile.create", "chief.profile.delete", "chief.profile.get", "chief.profile.history",
        "chief.profile.list", "chief.profile.undo", "chief.profile.update", "chief.stop",
        "client.list",
        "closed.delete", "closed.reopen",
        "column.update",
        "conversation.get", "conversation.list",
        "credential.mint",
        "git.files.list",
        "history.clear", "history.entries.list", "history.entries.remove", "history.site.remove",
        "history.trail.record", "history.visit.import", "history.visit.record", "history.visit.remove",
        "history.visit.summaries", "history.visit.title",
        "keybindings.get", "keybindings.remove", "keybindings.reset", "keybindings.set",
        "layout.bulk",
        "notification.clear",
        "origin.confirmation.issue",
        "palette_usage.forget", "palette_usage.get", "palette_usage.hide", "palette_usage.import",
        "palette_usage.record",
        "pane.focus",
        "project.add", "project.list", "project.observe", "project.sync",
        "screen.close", "screen.focus", "screen.get", "screen.move", "screen.rename", "screen.update",
        "screen_group.add_screens", "screen_group.create", "screen_group.remove_screens",
        "screen_group.ungroup", "screen_group.update",
        "session.events", "session.journal.subscribe",
        "sidebar.adopt", "sidebar.apply", "sidebar.get", "sidebar.item.add", "sidebar.item.remove",
        "sidebar.move", "sidebar.pin", "sidebar.section.add", "sidebar.section.remove", "sidebar.unpin",
        "sidebar_layout.get", "sidebar_layout.update",
        "stash.create", "stash.delete", "stash.import", "stash.list", "stash.restore",
        "tab.close", "tab.focus", "tab.pin", "tab.unpin", "tab.update",
        "tab_group.add_tabs", "tab_group.close", "tab_group.create", "tab_group.move",
        "tab_group.remove_tabs", "tab_group.ungroup", "tab_group.update",
        "terminal.history.clear", "terminal.input.write", "terminal.project", "terminal.wait_exit",
        "window_record.delete", "window_record.list", "window_record.put",
        "workspace.agent_folder.set", "workspace.agent_start.get", "workspace.create",
        "workspace.ensure_home", "workspace.open_url", "workspace.place", "workspace.update",
        "workspace_checklist.add", "workspace_checklist.remove", "workspace_checklist.update",
        "workspace_group.create", "workspace_group.delete", "workspace_group.move",
        "workspace_group.update",
    ]
}
