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
        if daemon.store.session.known {
            if daemon.store.servesStateResources, let zoom = tab.zoom { TerminalFontScale(session.surfaceView).apply(zoom) }
        } else {
            Self.applyFontScaleWhenKnown(tab: key, view: session.surfaceView, daemon: daemon)
        }
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

    /// A view made before the store knows its tab records takes its record's scale once the
    /// session stream's first snapshot arrives (cx-mer6v: a relaunch draws the launch window
    /// from the launch snapshot before the daemon answers, and the view outlives the handshake).
    /// A view whose font changed in the meantime keeps that size and saves it instead.
    private static func applyFontScaleWhenKnown(tab key: String, view: TerminalSurfaceView, daemon: DaemonService) {
        // task-owner: ends once the store knows its records, or when the view or the daemon goes
        Task { @MainActor [weak view, weak daemon] in
            while let store = daemon?.store, !store.session.known {
                await store.sessionStateResolved()
                if view == nil { return }
            }
            guard let view, let daemon, daemon.store.servesStateResources, let tab = tabModel(key, daemon: daemon) else { return }
            let fontScale = TerminalFontScale(view)
            if let local = fontScale.current {
                saveFontScale(local, tab: key, daemon: daemon)
            } else if let zoom = tab.zoom {
                fontScale.apply(zoom)
            }
        }
    }

    private static func tabModel(_ key: String, daemon: DaemonService) -> TabModel? {
        daemon.store.workspaces.lazy.flatMap(\.screens).flatMap(\.panes).flatMap(\.tabs).first { $0.id == key }
    }

    /// Saves `scale` on the record of tab `key` when it differs.
    static func saveFontScale(_ scale: Double?, tab key: String, daemon: DaemonService) {
        guard daemon.store.servesStateResources, let tab = tabModel(key, daemon: daemon),
              let resource = tab.resourceID, !sameScale(tab.zoom, scale) else { return }
        let zoom: FieldUpdate<Double> = scale.map(FieldUpdate.set) ?? .clear
        daemon.send("tab.update") { try await $0.state.updateTabRecord(resource, zoom: zoom) }
    }

    /// True for scales within the rounding `TerminalFontScale.apply` does (0.01 points), so a
    /// view that applied its record's scale writes nothing back.
    private static func sameScale(_ a: Double?, _ b: Double?) -> Bool {
        switch (a, b) {
        case (nil, nil): true
        case let (a?, b?): abs(a - b) < 0.001
        default: false
        }
    }
}
