public import CmuxNextDaemon
import CmuxNextLayout

/// ZOOM VARIANTS film selector (`FilmZoomVariant`; DEBUG and bench builds only, branch zoom-variants/film-selector-nomerge,
/// never merged): Z1, Z2 and Z3 show a zoom in the key's turn, as a store intent the daemon's echo settles, instead of
/// waiting for that echo (the current zoom, V0).
extension DaemonService {
    /// When a film zoom plays: shows `pane` zoomed in (or back out, when its screen shows it zoomed) now, lets `shown` lay
    /// it out in this turn, sends the command and returns true. False (always in a release build): the current zoom.
    public func filmZoomNow(_ pane: PaneModel, shown: @MainActor () -> Void) -> Bool {
        #if DEBUG || CMUX_BENCH_HOOKS
        guard LayoutModel.filmZoomPlays, connection != nil, let screen = store.screen(containing: pane.handle) else { return false }
        let handle = pane.handle
        let on = screen.zoomedPane != handle
        // ZOOM VARIANTS 2 key-turn attribution (`zk.*` spans, only while debug.motion records).
        let send = LayoutModel.filmTrace("zk.intent") {
            intendNow("zoom-pane", .zoomPane(screen: screen.handle, pane: on ? handle : nil), transaction: .generate()) {
                try await $0.zoomPane(handle, mode: on ? .on : .off)
            }
        }
        LayoutModel.filmTrace("zk.shown") { shown() }
        Task { _ = await send() }
        return true
        #else
        return false
        #endif
    }
}
