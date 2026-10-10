import CmuxNextDaemon
import CmuxNextTerminal
import Foundation

// A terminal's font zoom lives on its tab record (`tab.update` zoom, the
// font scale; state-ownership.md 2) on daemons with state resources: a new
// terminal view starts at its record's scale, and every font size change
// (keyboard, menu, palette, CLI, the workspace-wide verbs) is saved there.
extension TabContentCache {
    /// A session for `tab` that follows its record's font scale.
    func makeSession(io: DaemonTerminalIO, tab: TabModel, daemon: DaemonService) -> TerminalSession {
        let session = TerminalSession(io: io, ownsGeometry: true)
        session.delegate = sessionDelegate
        let key = tab.id
        if daemon.store.servesStateResources, let zoom = tab.zoom { TerminalFontScale(session.surfaceView).apply(zoom) }
        TerminalFontScale(session.surfaceView).observe { [weak daemon, weak surfaceView = session.surfaceView] scale in
            guard let daemon else { return }
            Self.saveFontScale(scale, tab: key, daemon: daemon)
            // Ghostty handles Cmd+=/-/0 directly, so show the same transient readout
            // as the action/palette path when the changed terminal owns the key window.
            if let surfaceView, surfaceView.window?.isKeyWindow == true {
                SurfaceZoomIndicator.show(percent: Int(((scale ?? 1) * 100).rounded()), in: surfaceView.window)
            }
        }
        return session
    }

    /// Saves `scale` on the record of tab `key` when it differs.
    static func saveFontScale(_ scale: Double?, tab key: String, daemon: DaemonService) {
        guard daemon.store.servesStateResources,
              let tab = daemon.store.workspaces.lazy.flatMap(\.screens).flatMap(\.panes).flatMap(\.tabs).first(where: { $0.id == key }),
              let resource = tab.resourceID, tab.zoom != scale else { return }
        let zoom: FieldUpdate<Double> = scale.map(FieldUpdate.set) ?? .clear
        daemon.send("tab.update") { try await $0.state.updateTabRecord(resource, zoom: zoom) }
    }
}
