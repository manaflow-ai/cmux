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
/// `VSyncCallbackMac` with its display's `DisplayLinkMac` while the frame sink needs begin frames,
/// moves to the new display's link when the display changes, and paces on a `DelayBasedTimeSource`
/// (`components/viz/common/frame_sinks/delay_based_time_source.cc`) while no link can be made; cc stops
/// asking after a begin frame with nothing to draw (`cc/scheduler/scheduler_state_machine.cc`,
/// `BeginFrameNeeded`).
///
/// - A surface that draws (``TerminalSurfaceView/pause`` is nil) holds one subscription to its display;
///   a hidden, parked, suspended or occluded one holds none (``follow(_:source:)``).
/// - A display with no screen gives the surface the main display's clock; with no screen there either,
///   it ticks on a ``linklessInterval`` deadline while Ghostty wants frames. Off its own display's
///   clock, it tries that display again every ``retryInterval`` and on every ``follow(_:source:)``.
/// - Ghostty's `vsync_wanted_cb` (renderer thread) arms that subscription on true; the subscription is
///   made on main, disarmed, so the wanted edges never reach the main thread, and a disarmed subscriber
///   leaves its display's link paused.
/// - Each armed tick (hub thread) calls `ghostty_surface_vsync`. The first tick after Ghostty said false
///   draws nothing and returns ``VSyncHub/Demand/done``, which disarms it.
/// - ``close()`` runs before `ghostty_surface_free`: no tick reaches the surface after it returns.
///   Ghostty's callback reaches the pacer through the surface's ``SurfaceBridge``, which owns it.
///
/// One `Mutex` holds the state. A tick keeps it across `ghostty_surface_vsync`, which only notifies the
/// renderer thread, so ``close()`` cannot return while a tick is inside Ghostty; nothing else calls out
/// with it held.
nonisolated final class TerminalVSync: Sendable {
    /// The linkless deadline's period: Chrome's `BeginFrameArgs::DefaultInterval()`, 60 Hz
    /// (`components/viz/common/frame_sinks/begin_frame_args.h`).
    static let linklessInterval: Duration = .nanoseconds(16_666_667)
    /// How often a surface off its own display's clock tries that display again (``DisplayClock``'s stall
    /// timeout, which retries a linkless display as often).
    static let retryInterval: Duration = .milliseconds(100)

    private struct State {
        /// Ghostty's last `vsync_wanted_cb` value.
        var wanted = false
        /// One refresh of the surface (`ghostty_surface_vsync`); nil until ``attach(refresh:)``.
        var refresh: (@Sendable () -> Void)?
        var subscription: (any TerminalVSyncSubscription)?
        /// The display the surface draws on (``follow(_:source:)``); nil: it does not draw.
        var requested: CGDirectDisplayID?
        /// The display ``subscription`` is on: ``requested``, the fallback, or nil when none could be made.
        var subscribed: CGDirectDisplayID?
        /// Counts subscriptions: a tick of an earlier one draws nothing.
        var generation: UInt64 = 0
        var closed = false

        /// Ticks on its own display's clock, or does not draw: nothing to try again.
        var onOwnClock: Bool { requested == nil || subscribed == requested }
        /// Draws with no subscription at all: the linkless deadline paces it.
        var linkless: Bool { !closed && requested != nil && subscription == nil }
    }

    private let state = Mutex(State())
    /// Names the surface's subscriptions in the hub's debug output.
    private let owner: String
    /// The display a surface subscribes to when its own has no screen (the main display).
    private let fallback: @Sendable () -> CGDirectDisplayID
    /// Ticks a linkless surface while Ghostty wants frames (``linklessInterval``, off main).
    private let linklessDeadline: DemandTimer
    /// Tries the surface's own display again while it is off that display's clock (``retryInterval``, main).
    private let retryDeadline: DemandTimer
    /// The source of the last ``follow(_:source:)``, which a retry subscribes through.
    @MainActor private var source: (any TerminalVSyncSource)?

    /// - Parameters:
    ///   - owner: Names the surface's subscriptions in the hub's debug output.
    ///   - fallback: The display to tick from when the surface's own has no screen.
    ///   - pacingClock: Times the linkless deadline.
    ///   - retryClock: Times the retries of the surface's own display.
    ///   - ledger: Where both deadlines record their wakeups.
    init(owner: String = "terminal", fallback: @escaping @Sendable () -> CGDirectDisplayID = { CGMainDisplayID() },
         pacingClock: any Clock<Duration> = ContinuousClock(), retryClock: any Clock<Duration> = ContinuousClock(),
         ledger: WakeupLedger = .shared) {
        self.owner = owner
        self.fallback = fallback
        linklessDeadline = DemandTimer(owner: "TerminalVSync.linkless", policy: .precise, clock: pacingClock, ledger: ledger)
        retryDeadline = DemandTimer(owner: "TerminalVSync.retry", clock: retryClock, ledger: ledger)
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

    /// Ghostty's `vsync_wanted_cb`: true arms the subscription, or starts the linkless deadline when there
    /// is none; false lets the next tick stop.
    func wantedChanged(_ wanted: Bool) {
        let wake = state.withLock { state -> (subscription: (any TerminalVSyncSubscription)?, linkless: Bool) in
            state.wanted = wanted
            return wanted ? (state.subscription, state.linkless) : (nil, false)
        }
        wake.subscription?.arm()
        if wake.linkless { scheduleLinklessTick() }
    }

    // MARK: Main thread

    /// Subscribes to `display`'s vsync while the surface draws, or leaves when `display` is nil (hidden,
    /// parked, suspended or occluded). A new display moves the subscription. The same display changes
    /// nothing once the surface is on that display's clock, and tries that display again until then.
    @MainActor func follow(_ display: CGDirectDisplayID?, source: any TerminalVSyncSource) {
        let next = state.withLock { state -> UInt64? in
            guard !state.closed, display != state.requested || !state.onOwnClock else { return nil }
            return state.generation &+ 1
        }
        guard let generation = next else { return }
        self.source = source
        guard let display else {
            install(nil, on: nil, requested: nil, generation: generation)
            return
        }
        let onVSync: @Sendable (VSyncHub.Tick) -> VSyncHub.Demand = { [weak self] _ in
            self?.tick(generation) ?? .done
        }
        if let own = source.subscribeSurface(to: display, owner: owner, onVSync: onVSync) {
            install(own, on: display, requested: display, generation: generation)
            return
        }
        let main = fallback()
        let onMain = state.withLock { state -> Bool in
            guard main != display, state.subscription != nil, state.subscribed == main else { return false }
            state.requested = display
            return true
        }
        if onMain {
            // Already on the main display's clock: it stays there until its own display has a screen.
            scheduleRetry()
            return
        }
        let made = main == display ? nil : source.subscribeSurface(to: main, owner: owner, onVSync: onVSync)
        install(made, on: made == nil ? nil : main, requested: display, generation: generation)
    }

    /// Makes `made` (on `subscribed`) the surface's subscription for `requested`, armed when Ghostty wants
    /// frames, then leaves the old one, so a display's link stays up when the old and new share it.
    @MainActor private func install(_ made: (any TerminalVSyncSubscription)?, on subscribed: CGDirectDisplayID?,
                                    requested: CGDirectDisplayID?, generation: UInt64) {
        let swap = state.withLock { state -> (old: (any TerminalVSyncSubscription)?, arm: Bool, pace: Bool, ownClock: Bool)? in
            guard !state.closed else { return nil }
            let old = state.subscription
            state.generation = generation
            state.requested = requested
            state.subscription = made
            state.subscribed = made == nil ? nil : subscribed
            return (old, state.wanted, state.linkless && state.wanted, state.onOwnClock)
        }
        guard let swap else {
            made?.cancel()
            return
        }
        // Stored before `wanted` was read: an edge that came earlier arms here, a later one arms it itself.
        if swap.arm { made?.arm() }
        swap.old?.cancel()
        if swap.pace { scheduleLinklessTick() }
        if swap.ownClock { retryDeadline.cancel() } else { scheduleRetry() }
    }

    @MainActor private func scheduleRetry() {
        retryDeadline.scheduleOnMainIfIdle(after: Self.retryInterval) { [weak self] in self?.retryOwnDisplay() }
    }

    /// The surface is off its own display's clock: subscribe to that display if it has a screen now.
    @MainActor private func retryOwnDisplay() {
        guard let source else { return }
        let requested = state.withLock { state -> CGDirectDisplayID? in
            state.closed || state.onOwnClock ? nil : state.requested
        }
        guard let requested else { return }
        follow(requested, source: source)
    }

    /// Leaves the hub for good: no tick calls into the surface after this returns. Call before
    /// `ghostty_surface_free`.
    @MainActor func close() {
        let old = state.withLock { state -> (any TerminalVSyncSubscription)? in
            state.closed = true
            state.refresh = nil
            state.requested = nil
            state.subscribed = nil
            defer { state.subscription = nil }
            return state.subscription
        }
        old?.cancel()
        linklessDeadline.cancel()
        retryDeadline.cancel()
        source = nil
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

    // MARK: Linkless deadline

    private func scheduleLinklessTick() {
        linklessDeadline.scheduleIfIdle(after: Self.linklessInterval) { [weak self] in self?.linklessTick() }
    }

    /// One linkless tick: a refresh and the next deadline while the surface has no subscription and
    /// Ghostty wants frames; otherwise the deadline stops until a wanted edge or a linkless install.
    private func linklessTick() {
        let again = state.withLock { state -> Bool in
            guard state.linkless, state.wanted, let refresh = state.refresh else { return false }
            refresh()
            return true
        }
        if again { scheduleLinklessTick() }
    }

    // MARK: Debug

    /// Whether the surface holds a subscription now (only while it draws).
    var isSubscribed: Bool { state.withLock { $0.subscription != nil } }
}
