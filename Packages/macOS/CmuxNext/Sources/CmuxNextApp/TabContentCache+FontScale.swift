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
        if daemon.store.servesStateResources, let zoom = tab.zoom { TerminalFontScale.apply(zoom, to: session.surfaceView) }
        TerminalFontScale.observe(session.surfaceView) { [weak daemon] scale in
            guard let daemon else { return }
            Self.saveFontScale(scale, tab: key, daemon: daemon)
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
