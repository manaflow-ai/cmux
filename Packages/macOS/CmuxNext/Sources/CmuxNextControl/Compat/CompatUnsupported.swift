import Foundation

/// Reasons for old v2 methods cmux-next does not implement. Every method in
/// a known old namespace gets a typed `unsupported in cmux-next: <reason>`
/// error instead of `method_not_found`, a hang, or a silent success.
enum CompatUnsupported {
    /// Specific methods, checked before their namespace.
    static let methods: [String: String] = [
        "workspace.last": "focus history is not tracked by cmux-next yet",
        "workspace.move_to_window": "windows do not own workspaces in cmux-next; any window can show any workspace",
        "workspace.reorder_many": "batch reorder is not implemented; call workspace.reorder per workspace",
        "workspace.action": "use the action registry instead: cmux action list / cmux action run <id>",
        "workspace.set_auto_title": "agent auto-naming moves to cmux-tui report-agent",
        "workspace.equalize_splits": "equalize is not implemented by cmux-tui yet",
        "workspace.env": "per-workspace environment is not stored by cmux-tui",
        "surface.trigger_flash": "the attention flash is not implemented in cmux-next yet",
        "surface.drag_to_split": "use surface.move with pane_id, or cmux-tui move-tab-to-split",
        "surface.split_off": "use surface.move with pane_id, or cmux-tui move-tab-to-split",
        "surface.respawn": "respawn is not implemented; close the tab and create a new one",
        "surface.read_selection": "selection lives in the terminal view; not exposed yet",
        "surface.refresh": "cmux-next surfaces redraw from cmux-tui deltas; nothing to refresh",
        "surface.report_pwd": "cmux-tui derives cwd from OSC 7",
        "surface.report_git_branch": "cmux-tui derives the git branch per tab",
        "surface.clear_git_branch": "cmux-tui derives the git branch per tab",
        "surface.sync_codex_native_title": "agent titles move to cmux-tui report-agent",
        "surface.catalog": "the surface catalog is not implemented in cmux-next yet",
        "surface.project": "surface projection is part of Cloud VM sync, not cmux-next yet",
        "pane.resize": "resize is not implemented; drag the divider or use cmux-tui set-split-ratio",
        "pane.break": "use surface.move to a new pane instead",
        "pane.join": "use surface.move with pane_id instead",
        "pane.last": "focus history is not tracked by cmux-next yet",
        "system.top": "process accounting is not implemented in cmux-next yet",
        "system.memory": "memory accounting is not implemented in cmux-next yet",
        "browser.wait": "page waits are not implemented; poll with browser eval",
        "browser.screenshot": "page screenshots are not exposed over the socket yet",
        "notification.open": "open the notification's surface with surface.focus",
    ]

    /// Whole namespaces, by prefix before the first dot.
    static let namespaces: [String: String] = [
        "workspace": "this workspace operation is not implemented in cmux-next",
        "surface": "this surface operation is not implemented in cmux-next",
        "pane": "this pane operation is not implemented in cmux-next",
        "window": "this window operation is not implemented in cmux-next",
        "tab": "this tab operation is not implemented in cmux-next",
        "terminal": "this terminal operation is not implemented in cmux-next",
        "notification": "this notification operation is not implemented in cmux-next",
        "system": "this system method is not implemented in cmux-next",
        "browser": "this browser automation method is not implemented in cmux-next yet (see cli-compat.md)",
        "debug": "debug-only methods of the old app are not part of cmux-next",
        "app": "focus overrides are a debug feature of the old app",
        "layout": "saved layouts are not implemented in cmux-next yet",
        "session": "session restore is owned by cmux-tui; the app has nothing to restore",
        "agent": "agent state moves to cmux-tui report-agent; not mapped yet",
        "feed": "feed replies need the old app's decision UI; cmux-next stores feed.push attention events as notifications",
        "sidebar": "custom sidebars are not part of cmux-next yet",
        "vm": "Cloud VMs are not wired into cmux-next yet",
        "cloud": "Cloud VMs are not wired into cmux-next yet",
        "remote": "the remote tmux mirror is replaced by cmux-remote",
        "remotes": "remote machines are not wired into cmux-next yet",
        "mobile": "the iOS bridge is not wired into cmux-next yet",
        "simulator": "the simulator pane is not part of cmux-next",
        "canvas": "canvas layout was removed in cmux-next",
        "markdown": "the Markdown viewer is not part of cmux-next yet",
        "file": "the file preview is not part of cmux-next yet",
        "vault": "the session vault is not part of cmux-next yet",
        "project": "projects are not part of cmux-next yet",
        "comments": "comments are not part of cmux-next yet",
        "chat": "agent chat is not part of cmux-next yet",
        "auth": "sign-in is not wired into cmux-next yet",
        "coderouter": "coderouter is not wired into cmux-next yet",
        "automation": "automations are not part of cmux-next yet",
        "extension": "extensions are not part of cmux-next yet",
        "sync": "sync is not part of cmux-next yet",
        "phone_push": "phone push is not wired into cmux-next yet",
        "feedback": "feedback is not wired into cmux-next yet",
        "caffeine": "keep-awake is not part of cmux-next yet",
        "provider": "surface providers are not part of cmux-next yet",
        "current": "use system.identify or system.tree",
    ]

    static func reason(for method: String) -> String? {
        if let reason = methods[method] { return reason }
        guard let dot = method.firstIndex(of: ".") else { return nil }
        return namespaces[String(method[..<dot])]
    }
}
