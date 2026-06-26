public import Foundation
public import GhosttyKit

// MARK: - Close-confirmation query (non-blocking, off-main)

/// Carries a surface pointer across the main/background boundary for the off-main
/// close-confirmation probe.
///
/// `@unchecked Sendable` because `ghostty_surface_t` is an opaque pointer the
/// compiler can't reason about (the same reason `TerminalSurfaceRuntimeTeardownRequest`
/// is `@unchecked Sendable`); the pointer is only read by the probe, never
/// dereferenced by Swift.
private final class NeedsConfirmCloseProbe: @unchecked Sendable {
    let surface: ghostty_surface_t

    init(surface: ghostty_surface_t) {
        self.surface = surface
    }
}

/// Main-thread-confined cache of the last off-main close-confirmation result.
///
/// `needsConfirmClose()` reads ``value`` synchronously on the main thread so the
/// session autosave tick never blocks on the surface's renderer lock (#6381); the
/// off-main refresh writes it back through `DispatchQueue.main.async`.
/// `@unchecked Sendable` so that hop can carry the cache without capturing the
/// non-Sendable surface model — every field is only ever touched on the main
/// thread, so there is no concurrent access to synchronize.
final class NeedsConfirmCloseCache: @unchecked Sendable {
    /// Seeded to `true` — the conservative side — so a cold cache (before the
    /// first off-main refresh lands) errs toward "confirmation required", which
    /// persists scrollback and prompts on close rather than silently dropping
    /// either. The autosave snapshot is the only persistence consumer and it
    /// reads `panelShellActivityState` first, treating this as a fallback only
    /// when that authoritative signal is `.unknown`.
    var value = true
    var refreshInFlight = false
}

extension TerminalSurface {
    /// Whether closing this surface should ask for confirmation.
    ///
    /// `ghostty_surface_needs_confirm_quit` ultimately takes the surface's
    /// `renderer_state` mutex (to read whether the cursor sits at a shell
    /// prompt) — the same lock held by the surface's renderer and IO threads.
    /// Calling it synchronously on the main thread, as the session autosave tick
    /// does through `Workspace.sessionPanelSnapshot`, parks the main thread in
    /// `_os_unfair_lock_lock_slow` -> `__ulock_wait2` forever whenever one of
    /// those threads is wedged holding the lock, beach-balling the whole app with
    /// no recovery short of `kill -9` (https://github.com/manaflow-ai/cmux/issues/6381).
    ///
    /// So the main thread never queries it synchronously: it returns the value
    /// last computed off the main thread (``NeedsConfirmCloseCache``) and kicks a
    /// background refresh for next time. The cache is a fallback that only feeds
    /// `Workspace.resolveCloseConfirmation` when cmux's own, fresher
    /// `panelShellActivityState` is `.unknown`, so a slightly stale value is a
    /// safe degradation for every main-thread caller (the autosave snapshot and
    /// the close/quit confirmation prompts) and beats hanging the app. Off-main
    /// callers keep the direct synchronous query.
    public func needsConfirmClose() -> Bool {
#if DEBUG
        if let needsConfirmCloseOverrideForTesting {
            return needsConfirmCloseOverrideForTesting
        }
#endif
        guard let surface = surface else { return false }
        guard Thread.isMainThread else {
            return ghostty_surface_needs_confirm_quit(surface)
        }
        // On the main thread: return the value last computed off-main and kick a
        // background refresh for next time. Never query ghostty synchronously.
        refreshNeedsConfirmCloseCacheIfIdle(surface)
        return needsConfirmCloseCache.value
    }

    /// Recomputes ``NeedsConfirmCloseCache/value`` off the main thread unless a
    /// refresh is already in flight. The query runs on a background queue and the
    /// result is stored back on the main thread, so the main thread never blocks
    /// on the surface's renderer lock. A permanently wedged surface leaks at most
    /// one background probe (the in-flight guard suppresses further refreshes
    /// until it returns), never one per autosave tick.
    ///
    /// Must be called on the main thread: ``needsConfirmCloseCache`` is
    /// main-thread-confined (read here and written only from `DispatchQueue.main`),
    /// which is why no lock is needed despite the background hop.
    ///
    /// - Parameter probe: The close-confirmation query, defaulting to
    ///   `ghostty_surface_needs_confirm_quit`. Tests inject a replacement to
    ///   simulate a slow/wedged surface lock (mirrors the teardown coordinator's
    ///   `freeSurface` injection point).
    func refreshNeedsConfirmCloseCacheIfIdle(
        _ surface: ghostty_surface_t,
        probe: @escaping @Sendable (ghostty_surface_t) -> Bool = { ghostty_surface_needs_confirm_quit($0) }
    ) {
        let cache = needsConfirmCloseCache
        guard !cache.refreshInFlight else { return }
        cache.refreshInFlight = true
        let pending = NeedsConfirmCloseProbe(surface: surface)
        Self.needsConfirmCloseProbeQueue.async {
            let value = probe(pending.surface)
            DispatchQueue.main.async {
                cache.value = value
                cache.refreshInFlight = false
            }
        }
    }

    /// Background queue for the off-main close-confirmation probe. Concurrent so
    /// one wedged surface never head-of-line-blocks probes for other surfaces.
    private static let needsConfirmCloseProbeQueue = DispatchQueue(
        label: "com.cmuxterm.terminal.needs-confirm-close-probe",
        qos: .utility,
        attributes: .concurrent
    )
}
