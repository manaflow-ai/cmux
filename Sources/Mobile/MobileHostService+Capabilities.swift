import Foundation

extension MobileHostService {
    /// The single source of truth for the capabilities advertised to mobile
    /// clients via `mobile.host.status`. Every status path (the public-status
    /// cache, the live `publicHostStatusResult`, and `TerminalController`'s
    /// full status) reads this so the lists cannot drift; iOS gates features
    /// like rename/pin on the entries present here.
    ///
    /// In DEBUG builds this also advertises `dogfood.v1`, the DEV dogfood
    /// feedback round-trip (`dogfood.feedback.submit`). It is absent from
    /// release builds, so a release client never sees the verb advertised.
    nonisolated static var mobileHostCapabilities: [String] {
        var capabilities = [
            "events.v1",
            "terminal.bytes.v1",
            "terminal.render_grid.v1",
            "terminal.replay.v1",
            "terminal.viewport.v1",
            "workspace.actions.v1",
            // The workspace list carries group sections (group_id per workspace +
            // a top-level groups array) and the host accepts
            // workspace.group.collapse/expand from mobile. iOS feature-detects
            // this to render collapsible groups only against a Mac that emits them.
            "workspace.groups.v1",
        ]
        #if DEBUG
        capabilities.append("dogfood.v1")
        #endif
        return capabilities
    }
}
