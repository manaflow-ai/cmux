import CmuxNextCompat
import CmuxNextWakeups
import CoreGraphics
import GhosttyNextKit

/// Where a terminal surface's vsync comes from: the app's ``VSyncHub`` (a fake in tests).
@MainActor protocol TerminalVSyncSource: AnyObject {
    /// A disarmed subscription to `display`'s vsync (``VSyncHub/subscribe(to:owner:armed:onVSync:)``);
    /// `onVSync` runs off main at each vsync while it is armed. Nil when `display` has no screen.
    func subscribeSurface(to display: CGDirectDisplayID, owner: String,
                          onVSync: @escaping @Sendable (VSyncHub.Tick) -> VSyncHub.Demand) -> (any TerminalVSyncSubscription)?
}

/// One subscription of a ``TerminalVSyncSource``: arm from any thread, cancel on main.
nonisolated protocol TerminalVSyncSubscription: AnyObject, Sendable {
    func arm()
    @MainActor func cancel()
}

extension VSyncHub: TerminalVSyncSource {
    func subscribeSurface(to display: CGDirectDisplayID, owner: String,
                          onVSync: @escaping @Sendable (VSyncHub.Tick) -> VSyncHub.Demand) -> (any TerminalVSyncSubscription)? {
        let subscription: VSyncHub.Subscription? = subscribe(to: display, owner: owner, armed: false, onVSync: onVSync)
        return subscription
    }
}

nonisolated extension VSyncHub.Subscription: TerminalVSyncSubscription {}

/// Paces one Ghostty surface from its display's ``VSyncHub`` thread (ghostty-next external vsync,
/// p03-rendering-082), so the app runs one display link per display instead of one CVDisplayLink per
/// surface (DC1).
///
/// Chrome's form: `components/viz/service/frame_sinks/external_begin_frame_source_mac.cc` registers a
/// `VSyncCallbackMac` with its display's `DisplayLinkMac` while the frame sink needs begin frames and
/// moves to the new display's link when the display changes; cc stops asking after a begin frame with
/// nothing to draw (`cc/scheduler/scheduler_state_machine.cc`, `BeginFrameNeeded`).
///
/// - A surface that draws (``TerminalSurfaceView/pause`` is nil) holds one subscription to its display;
///   a hidden, parked, suspended or occluded one holds none (``follow(_:source:)``).
/// - Ghostty's `vsync_wanted_cb` (renderer thread) arms that subscription on true; the subscription is
///   made on main, disarmed, so the wanted edges never reach the main thread, and a disarmed subscriber
///   leaves its display's link paused.
/// - Each armed tick (hub thread) calls `ghostty_surface_vsync`. The first tick after Ghostty said false
///   draws nothing and returns ``VSyncHub/Demand/done``, which disarms it.
/// - ``close()`` runs before `ghostty_surface_free`: no tick reaches the surface after it returns.
///
/// One `Mutex` holds the state. A tick keeps it across `ghostty_surface_vsync`, which only notifies the
/// renderer thread, so ``close()`` cannot return while a tick is inside Ghostty; nothing else calls out
/// with it held.
nonisolated final class TerminalVSync: Sendable {
    private struct State {
        /// Ghostty's last `vsync_wanted_cb` value.
        var wanted = false
        /// One refresh of the surface (`ghostty_surface_vsync`); nil until ``attach(refresh:)``.
        var refresh: (@Sendable () -> Void)?
        var subscription: (any TerminalVSyncSubscription)?
        /// The display ``follow(_:source:)`` last asked for (the subscription may be on the fallback).
        var requested: CGDirectDisplayID?
        /// Counts subscriptions: a tick of an earlier one draws nothing.
        var generation: UInt64 = 0
        var closed = false
    }

    private let state = Mutex(State())
    /// Names the surface's subscriptions in the hub's debug output.
    private let owner: String
    /// The display a surface subscribes to when its own has no screen (the main display).
    private let fallback: @Sendable () -> CGDirectDisplayID

    init(owner: String = "terminal", fallback: @escaping @Sendable () -> CGDirectDisplayID = { CGMainDisplayID() }) {
        self.owner = owner
        self.fallback = fallback
    }

    /// The source a new surface runs on: `hub`, or nil when the pinned GhosttyNextKit has no external
    /// vsync (`GHOSTTY_EXTERNAL_VSYNC`, Package.swift) or the app runs without a hub (feature `vsyncHub`).
    /// Without one, Ghostty paces each surface with its own display link, as before.
    @MainActor static func source(_ hub: VSyncHub?) -> (any TerminalVSyncSource)? {
        #if GHOSTTY_EXTERNAL_VSYNC
        hub
        #else
        nil
        #endif
    }

    /// Turns external vsync on in a surface's config, with this pacer as the `vsync_wanted_cb`'s userdata
    /// (``ghosttySurfaceVSyncWanted(_:_:)``). The caller keeps the pacer alive until `ghostty_surface_free`
    /// returns, after which Ghostty starts no call. Without the export (`GHOSTTY_EXTERNAL_VSYNC` off) the
    /// config is left as it is.
    func setExternal(in config: inout ghostty_surface_config_s) {
        #if GHOSTTY_EXTERNAL_VSYNC
        config.vsync_external = true
        // SAFETY: the callback has ghostty_surface_vsync_wanted_cb's signature.
        unsafe config.vsync_wanted_cb = ghosttySurfaceVSyncWanted
        // SAFETY: the caller keeps this pacer alive until ghostty_surface_free returns (above).
        unsafe config.vsync_userdata = Unmanaged.passUnretained(self).toOpaque()
        #endif
    }

    /// Ticks reach `surface` from now on, until ``close()``. The caller frees `surface` only after ``close()``.
    @MainActor func attach(surface: ghostty_surface_t) {
        #if GHOSTTY_EXTERNAL_VSYNC
        // SAFETY: the view's surface, live until ghostty_surface_free, which its view calls only after
        // close(); close() clears this closure under the lock every tick holds while it calls it.
        let pointer = unsafe UncheckedPointer(raw: surface)
        attach {
            // SAFETY: as above.
            unsafe ghostty_surface_vsync(pointer.raw)
        }
        #endif
    }

    /// Ticks call `refresh` from now on, until ``close()`` (tests; ``attach(surface:)`` in the app).
    func attach(refresh: @escaping @Sendable () -> Void) {
        state.withLock { state in
            guard !state.closed else { return }
            state.refresh = refresh
        }
    }

    // MARK: Renderer thread

    /// Ghostty's `vsync_wanted_cb`: true arms the subscription; false lets its next tick disarm it.
    func wantedChanged(_ wanted: Bool) {
        let subscription = state.withLock { state -> (any TerminalVSyncSubscription)? in
            state.wanted = wanted
            return wanted ? state.subscription : nil
        }
        subscription?.arm()
    }

    // MARK: Main thread

    /// Subscribes to `display`'s vsync while the surface draws, or leaves when `display` is nil (hidden,
    /// parked, suspended or occluded). A new display moves the subscription; the same one changes nothing.
    @MainActor func follow(_ display: CGDirectDisplayID?, source: any TerminalVSyncSource) {
        let change = state.withLock { state -> (old: (any TerminalVSyncSubscription)?, generation: UInt64)? in
            guard !state.closed, display != state.requested else { return nil }
            state.requested = display
            state.generation &+= 1
            defer { state.subscription = nil }
            return (state.subscription, state.generation)
        }
        guard let change else { return }
        change.old?.cancel()
        guard let display else { return }
        let generation = change.generation
        let onVSync: @Sendable (VSyncHub.Tick) -> VSyncHub.Demand = { [weak self] _ in
            self?.tick(generation) ?? .done
        }
        let made = source.subscribeSurface(to: display, owner: owner, onVSync: onVSync)
            ?? fallbackSubscription(display, source: source, onVSync: onVSync)
        guard let made else { return }
        // Stored before `wanted` is read: an edge that came earlier arms here, a later one arms it itself.
        let armNow = state.withLock { state -> Bool? in
            guard !state.closed, state.generation == generation else { return nil }
            state.subscription = made
            return state.wanted
        }
        switch armNow {
        case true?: made.arm()
        case false?: break
        case nil: made.cancel()
        }
    }

    /// The surface's display has no screen: its frames still pace, on the main display's clock.
    @MainActor private func fallbackSubscription(_ display: CGDirectDisplayID, source: any TerminalVSyncSource,
                                                 onVSync: @escaping @Sendable (VSyncHub.Tick) -> VSyncHub.Demand)
        -> (any TerminalVSyncSubscription)? {
        let main = fallback()
        guard main != display else { return nil }
        return source.subscribeSurface(to: main, owner: owner, onVSync: onVSync)
    }

    /// Leaves the hub for good: no tick calls into the surface after this returns. Call before
    /// `ghostty_surface_free`.
    @MainActor func close() {
        let old = state.withLock { state -> (any TerminalVSyncSubscription)? in
            state.closed = true
            state.refresh = nil
            state.requested = nil
            defer { state.subscription = nil }
            return state.subscription
        }
        old?.cancel()
    }

    // MARK: Hub thread

    /// One vsync of the subscription made at `generation`: a refresh while Ghostty wants one, else done.
    private func tick(_ generation: UInt64) -> VSyncHub.Demand {
        state.withLock { state -> VSyncHub.Demand in
            guard !state.closed, state.generation == generation, state.wanted, let refresh = state.refresh else {
                return .done
            }
            refresh()
            return .more
        }
    }

    // MARK: Debug

    /// Whether the surface holds a subscription now (only while it draws).
    var isSubscribed: Bool { state.withLock { $0.subscription != nil } }
}
