import CmuxNextDaemon
import CmuxNextTerminal
import CmuxNextWakeups
import Foundation

// A terminal's font zoom lives on its tab record (`tab.update` zoom, the
// font scale; state-ownership.md 2) on daemons with state resources: a new
// terminal view starts at its record's scale, and every font size change
// (keyboard, menu, palette, CLI, the workspace-wide verbs) is saved there.
extension TabContentCache {
    /// A session for `tab` that follows its record's font scale and the Ghostty config; its output
    /// lane is watched by `daemon`'s hang watch.
    func makeSession(io: any TerminalIO, tab: TabModel, daemon: DaemonService) -> TerminalSession {
        let key = tab.id, tabNode = node(for: key)
        let session = TerminalSession(io: io, ownsGeometry: true, hangWatch: daemon.hangWatch, modifiers: terminalModifiers,
                                      pointerFrames: terminalPointerFrames,
                                      mainWork: mainWork, node: tabNode, gpuResidency: gpuResidency,
                                      externalCursor: terminalExternalCursor,
                                      lowersHiddenOutput: streamFocus != nil)
        // It lays out after a Ghostty config change only while its tab is visible.
        session.view.followConfig(tabNode, on: mainWork)
        fontScaleWaits[key] = nil
        if daemon.store.session.known {
            if daemon.store.servesStateResources, let zoom = tab.zoom { TerminalFontScale(session.surfaceView).apply(zoom) }
        } else {
            applyFontScaleWhenKnown(tab: key, session: session, daemon: daemon)
        }
        TerminalFontScale(session.surfaceView).observe { [weak daemon, weak session, weak tabNode] scale in
            guard let daemon else { return }
            Self.saveFontScale(scale, tab: key, daemon: daemon)
            // Ghostty handles Cmd+=/-/0 directly, so show the same transient readout
            // as the action/palette path when the changed terminal shows in the key window.
            if let surfaceView = session?.surfaceView, surfaceView.window?.isKeyWindow == true, tabNode?.isVisible == true {
                SurfaceZoomIndicator.show(percent: Int(((scale ?? 1) * 100).rounded()), in: surfaceView.window)
            }
        }
        return session
    }

    /// A session made before the store knows its tab records gives its current surface (a replay may have
    /// swapped it, cx-1bauj) its record's scale once the session stream's first snapshot arrives (cx-mer6v:
    /// a relaunch draws the launch window from the launch snapshot before the daemon answers). A surface
    /// whose font changed meanwhile (a reset too) saves its size instead; a replaced session does neither.
    /// One ServiceObservation of `known`, held in ``fontScaleWaits`` until it applies or the tab goes: it
    /// applies in a posted task, also while the terminal is hidden (the record is model state).
    private func applyFontScaleWhenKnown(tab key: String, session: TerminalSession, daemon: DaemonService) {
        let records = daemon.store.session
        fontScaleWaits[key] = ServiceObservation(.visible, owner: "TerminalFontScale.whenKnown", on: mainWork) { [weak records] in
            records?.known ?? true
        } apply: { [weak self, weak session, weak daemon] known in
            guard known, let self else { return }
            fontScaleWaits[key] = nil
            guard let session, let daemon, existingTerminal(key)?.session === session,
                  daemon.store.servesStateResources, let tab = Self.tabModel(key, daemon: daemon) else { return }
            let fontScale = TerminalFontScale(session.surfaceView)
            if fontScale.changed {
                Self.saveFontScale(fontScale.current, tab: key, daemon: daemon)
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
