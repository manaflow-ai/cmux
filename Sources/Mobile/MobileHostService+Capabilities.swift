import Foundation

extension MobileHostService {
    /// The single source of truth for the capabilities advertised to mobile
    /// clients via `mobile.host.status`. Every status path (the public-status
    /// cache, the network status gate, and `TerminalController`'s
    /// full status) reads this so the lists cannot drift; iOS gates features
    /// like rename/pin/read-state/close on the entries present here.
    ///
    /// This also advertises `dogfood.v1`, the agent feedback round-trip
    /// (`dogfood.feedback.submit`). It is advertised on every build type so the
    /// privileged Send Feedback path (offered only to `@manaflow.ai` users on an
    /// active connection) works on Release (beta/prod) too; the sink itself is
    /// still gated by the same-account Stack-auth check the rest of the mobile
    /// data plane enforces.
    nonisolated static var mobileHostCapabilities: [String] {
        [
            "events.v1",
            "notification.badge.v1",
            "notification.dismiss.v1",
            "notification.reconcile.v1",
            "terminal.bytes.v1",
            // Bracketed-paste `terminal.paste` RPC. iOS routes multi-character
            // commits (dictation, autocorrect, keyboard/clipboard paste) here so
            // they land as one paste instead of fragmenting into per-key input;
            // it falls back to `terminal.input` against a Mac that omits this.
            "terminal.paste.v1",
            "terminal.render_grid.v1",
            "terminal.replay.v1",
            "terminal.viewport.v1",
            "workspace.actions.v1",
            "workspace.read_state.v1",
            "workspace.close.v1",
            "dogfood.v1",
            // The workspace list carries group sections (group_id per workspace +
            // a top-level groups array) and the host accepts
            // workspace.group.collapse/expand from mobile. iOS feature-detects
            // this to render collapsible groups only against a Mac that emits them.
            "workspace.groups.v1",
        ]
    }
}
