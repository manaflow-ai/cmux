import Foundation

extension MobileHostService {
    /// The single source of truth for the capabilities advertised to mobile
    /// clients via `mobile.host.status`. Every status path (the public-status
    /// cache, the network status gate, and `TerminalController`'s
    /// full status) reads this so the lists cannot drift; iOS gates features
    /// like rename/pin/read-state/close/move/group actions on the entries
    /// present here.
    ///
    /// This also advertises `dogfood.v1`, the agent feedback round-trip
    /// (`dogfood.feedback.submit`). It is advertised on every build type so the
    /// privileged Send Feedback path (offered only to `@manaflow.ai` users on an
    /// active connection) works on Release (beta/prod) too; the sink itself is
    /// still gated by the same-account Stack-auth check the rest of the mobile
    /// data plane enforces.
    nonisolated static var mobileHostCapabilities: [String] {
        let capabilities = [
            "events.v1",
            "notification.badge.v1",
            "notification.dismiss.v1",
            "notification.reconcile.v1",
            "terminal.bytes.v1",
            "terminal.render_grid.v1",
            "terminal.replay.v1",
            "terminal.viewport.v1",
            "terminal.artifact.v1",
            "workspace.actions.v1",
            "workspace.read_state.v1",
            "workspace.close.v1",
            "workspace.move.v1",
            "workspace.group_actions.v1",
            "workspace.group_create.v1",
            "workspace.create_in_group.v1",
            "chat.artifact.v1",
            "chat.artifact.gallery.v1",
            "dogfood.v1",
            // The workspace list carries group sections (group_id per workspace +
            // a top-level groups array) and the host accepts
            // workspace.group.collapse/expand from mobile. iOS feature-detects
            // this to render collapsible groups only against a Mac that emits them.
            "workspace.groups.v1",
        ]
        #if DEBUG
        // Lets a dev Mac impersonate an older host while dogfooding the iOS update hint.
        let suppressed = Set(
            (ProcessInfo.processInfo.environment["CMUX_DEBUG_SUPPRESS_MOBILE_CAPS"] ?? "")
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        )
        return capabilities.filter { !suppressed.contains($0) }
        #else
        return capabilities
        #endif
    }
}
