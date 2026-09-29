import Foundation

/// Reasons for old v2 methods cmux-next does not implement. Every method in
/// a known old namespace gets a typed `unsupported in cmux-next: <reason>`
/// error instead of `method_not_found`, a hang, or a silent success.
enum CompatUnsupported {
    /// Specific methods, checked before their namespace.
    static let methods: [String: String] = [
        "workspace.last": ControlStrings.text("control.unsupported.method.workspace.last", "focus history is not tracked by cmux-next yet"),
        "workspace.move_to_window": ControlStrings.text("control.unsupported.method.workspace.move_to_window", "windows do not own workspaces in cmux-next; any window can show any workspace"),
        "workspace.reorder_many": ControlStrings.text("control.unsupported.method.workspace.reorder_many", "batch reorder is not implemented; call workspace.reorder per workspace"),
        "workspace.action": ControlStrings.text("control.unsupported.method.workspace.action", "use the action registry instead: cmux action list / cmux action run <id>"),
        "workspace.set_auto_title": ControlStrings.text("control.unsupported.method.workspace.set_auto_title", "agent auto-naming moves to cmux-tui report-agent"),
        "workspace.equalize_splits": ControlStrings.text("control.unsupported.method.workspace.equalize_splits", "equalize is not implemented by cmux-tui yet"),
        "workspace.env": ControlStrings.text("control.unsupported.method.workspace.env", "per-workspace environment is not stored by cmux-tui"),
        "surface.trigger_flash": ControlStrings.text("control.unsupported.method.surface.trigger_flash", "the attention flash is not implemented in cmux-next yet"),
        "surface.drag_to_split": ControlStrings.text("control.unsupported.method.surface.drag_to_split", "use surface.move with pane_id, or cmux-tui move-tab-to-split"),
        "surface.split_off": ControlStrings.text("control.unsupported.method.surface.split_off", "use surface.move with pane_id, or cmux-tui move-tab-to-split"),
        "surface.respawn": ControlStrings.text("control.unsupported.method.surface.respawn", "respawn is not implemented; close the tab and create a new one"),
        "surface.read_selection": ControlStrings.text("control.unsupported.method.surface.read_selection", "selection lives in the terminal view; not exposed yet"),
        "surface.refresh": ControlStrings.text("control.unsupported.method.surface.refresh", "cmux-next surfaces redraw from cmux-tui deltas; nothing to refresh"),
        "surface.report_pwd": ControlStrings.text("control.unsupported.method.surface.report_pwd", "cmux-tui derives cwd from OSC 7"),
        "surface.report_git_branch": ControlStrings.text("control.unsupported.method.surface.report_git_branch", "cmux-tui derives the git branch per tab"),
        "surface.clear_git_branch": ControlStrings.text("control.unsupported.method.surface.clear_git_branch", "cmux-tui derives the git branch per tab"),
        "surface.sync_codex_native_title": ControlStrings.text("control.unsupported.method.surface.sync_codex_native_title", "agent titles move to cmux-tui report-agent"),
        "surface.catalog": ControlStrings.text("control.unsupported.method.surface.catalog", "the surface catalog is not implemented in cmux-next yet"),
        "surface.project": ControlStrings.text("control.unsupported.method.surface.project", "surface projection is part of Cloud VM sync, not cmux-next yet"),
        "pane.resize": ControlStrings.text("control.unsupported.method.pane.resize", "resize is not implemented; drag the divider or use cmux-tui set-split-ratio"),
        "pane.break": ControlStrings.text("control.unsupported.method.pane.break", "use surface.move to a new pane instead"),
        "pane.join": ControlStrings.text("control.unsupported.method.pane.join", "use surface.move with pane_id instead"),
        "pane.last": ControlStrings.text("control.unsupported.method.pane.last", "focus history is not tracked by cmux-next yet"),
        "system.top": ControlStrings.text("control.unsupported.method.system.top", "process accounting is not implemented in cmux-next yet"),
        "system.memory": ControlStrings.text("control.unsupported.method.system.memory", "memory accounting is not implemented in cmux-next yet"),
        "browser.wait": ControlStrings.text("control.unsupported.method.browser.wait", "page waits are not implemented; poll with browser eval"),
        "browser.screenshot": ControlStrings.text("control.unsupported.method.browser.screenshot", "page screenshots are not exposed over the socket yet"),
        "notification.open": ControlStrings.text("control.unsupported.method.notification.open", "open the notification's surface with surface.focus"),
    ]

    /// Whole namespaces, by prefix before the first dot.
    static let namespaces: [String: String] = [
        "workspace": ControlStrings.text("control.unsupported.namespace.workspace", "this workspace operation is not implemented in cmux-next"),
        "surface": ControlStrings.text("control.unsupported.namespace.surface", "this surface operation is not implemented in cmux-next"),
        "pane": ControlStrings.text("control.unsupported.namespace.pane", "this pane operation is not implemented in cmux-next"),
        "window": ControlStrings.text("control.unsupported.namespace.window", "this window operation is not implemented in cmux-next"),
        "tab": ControlStrings.text("control.unsupported.namespace.tab", "this tab operation is not implemented in cmux-next"),
        "terminal": ControlStrings.text("control.unsupported.namespace.terminal", "this terminal operation is not implemented in cmux-next"),
        "notification": ControlStrings.text("control.unsupported.namespace.notification", "this notification operation is not implemented in cmux-next"),
        "system": ControlStrings.text("control.unsupported.namespace.system", "this system method is not implemented in cmux-next"),
        "browser": ControlStrings.text("control.unsupported.namespace.browser", "this browser automation method is not implemented in cmux-next yet (see cli-compat.md)"),
        "debug": ControlStrings.text("control.unsupported.namespace.debug", "debug-only methods of the old app are not part of cmux-next"),
        "app": ControlStrings.text("control.unsupported.namespace.app", "focus overrides are a debug feature of the old app"),
        "layout": ControlStrings.text("control.unsupported.namespace.layout", "saved layouts are not implemented in cmux-next yet"),
        "session": ControlStrings.text("control.unsupported.namespace.session", "session restore is owned by cmux-tui; the app has nothing to restore"),
        "agent": ControlStrings.text("control.unsupported.namespace.agent", "agent state moves to cmux-tui report-agent; not mapped yet"),
        "feed": ControlStrings.text("control.unsupported.namespace.feed", "feed replies need the old app's decision UI; cmux-next stores feed.push attention events as notifications"),
        "sidebar": ControlStrings.text("control.unsupported.namespace.sidebar", "custom sidebars are not part of cmux-next yet"),
        "vm": ControlStrings.text("control.unsupported.namespace.vm", "Cloud VMs are not wired into cmux-next yet"),
        "cloud": ControlStrings.text("control.unsupported.namespace.cloud", "Cloud VMs are not wired into cmux-next yet"),
        "remote": ControlStrings.text("control.unsupported.namespace.remote", "the remote tmux mirror is replaced by cmux-remote"),
        "remotes": ControlStrings.text("control.unsupported.namespace.remotes", "remote machines are not wired into cmux-next yet"),
        "mobile": ControlStrings.text("control.unsupported.namespace.mobile", "the iOS bridge is not wired into cmux-next yet"),
        "simulator": ControlStrings.text("control.unsupported.namespace.simulator", "the simulator pane is not part of cmux-next"),
        "canvas": ControlStrings.text("control.unsupported.namespace.canvas", "canvas layout was removed in cmux-next"),
        "markdown": ControlStrings.text("control.unsupported.namespace.markdown", "the Markdown viewer is not part of cmux-next yet"),
        "file": ControlStrings.text("control.unsupported.namespace.file", "the file preview is not part of cmux-next yet"),
        "vault": ControlStrings.text("control.unsupported.namespace.vault", "the session vault is not part of cmux-next yet"),
        "project": ControlStrings.text("control.unsupported.namespace.project", "projects are not part of cmux-next yet"),
        "comments": ControlStrings.text("control.unsupported.namespace.comments", "comments are not part of cmux-next yet"),
        "chat": ControlStrings.text("control.unsupported.namespace.chat", "agent chat is not part of cmux-next yet"),
        "auth": ControlStrings.text("control.unsupported.namespace.auth", "sign-in is not wired into cmux-next yet"),
        "coderouter": ControlStrings.text("control.unsupported.namespace.coderouter", "coderouter is not wired into cmux-next yet"),
        "automation": ControlStrings.text("control.unsupported.namespace.automation", "automations are not part of cmux-next yet"),
        "extension": ControlStrings.text("control.unsupported.namespace.extension", "extensions are not part of cmux-next yet"),
        "sync": ControlStrings.text("control.unsupported.namespace.sync", "sync is not part of cmux-next yet"),
        "phone_push": ControlStrings.text("control.unsupported.namespace.phone_push", "phone push is not wired into cmux-next yet"),
        "feedback": ControlStrings.text("control.unsupported.namespace.feedback", "feedback is not wired into cmux-next yet"),
        "caffeine": ControlStrings.text("control.unsupported.namespace.caffeine", "keep-awake is not part of cmux-next yet"),
        "provider": ControlStrings.text("control.unsupported.namespace.provider", "surface providers are not part of cmux-next yet"),
        "current": ControlStrings.text("control.unsupported.namespace.current", "use system.identify or system.tree"),
    ]

    static func reason(for method: String) -> String? {
        if let reason = methods[method] { return reason }
        guard let dot = method.firstIndex(of: ".") else { return nil }
        return namespaces[String(method[..<dot])]
    }
}
