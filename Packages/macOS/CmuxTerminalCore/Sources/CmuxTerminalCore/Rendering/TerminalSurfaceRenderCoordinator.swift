public import AppKit
public import CoreGraphics
public import GhosttyKit
public import Observation

/// Owns the terminal surface's sizing, appearance, scrollbar, and rendered-frame
/// coalescing state and decisions, hosted by the live `GhosttyNSView`.
///
/// This coordinator lifts the resize/appearance cluster out of the
/// `GhosttyNSView` god file. It owns the transient render state (`scrollbar`,
/// `cellSize`, `backgroundColor`, the applied color scheme, and the size-retry
/// bookkeeping) plus the pure decisions (drag-resize deferral, drawable-size
/// derivation, color-scheme dedup, and debug signature dedup), and routes every
/// AppKit/Ghostty/app-target side effect back to the host through
/// ``TerminalSurfaceRenderHosting``.
///
/// ## Coalescing
///
/// High-frequency scrollbar and rendered-frame wakeups from the runtime's I/O
/// thread are coalesced through ``TerminalScrollbarObserving`` /
/// ``TerminalRenderObserving`` AsyncStreams (newest-wins), replacing the legacy
/// `DispatchQueue.main.async` flush schedule. A single consumer task per stream
/// drains on the main actor (where the surface state lives), so a burst
/// collapses to one delivery.
///
/// The scrollbar value itself lives in a lock-guarded pending slot
/// (`pendingScrollbar` + `pendingScrollbarLock`), faithfully preserving the
/// legacy `_pendingScrollbar` + `_scrollbarLock`. The stream is only the wakeup
/// that schedules the main-actor drain; the slot is the single source of truth
/// for whether an *un-drained* value exists. That distinction is load-bearing:
/// the copy-mode viewport-jump path calls ``flushPendingScrollbarIfAvailable()``
/// to synchronously test "is a fresh scrollbar pending, and if so flush it now",
/// which a buffered AsyncStream value cannot answer.
///
/// ## Latency fence
///
/// LATENCY-UNVERIFIED. This is the resize/appearance path, not the
/// per-keystroke path; `forceRefresh()`, `hitTest()`, keydown/IME, and the
/// per-frame tick loop deliberately do not route through this coordinator.
@MainActor
@Observable
public final class TerminalSurfaceRenderCoordinator {
    // MARK: Host seam

    /// The live `GhosttyNSView` host, held weakly to avoid a retain cycle.
    @ObservationIgnored
    public weak var host: (any TerminalSurfaceRenderHosting)?

    // MARK: Owned render state

    /// The latest applied scrollbar geometry snapshot.
    public var scrollbar: GhosttyScrollbar?

    /// The terminal cell size in points, posted from the runtime cell-size action.
    public var cellSize: CGSize = .zero

    /// The per-surface background override (OSC background), or `nil` to use the
    /// default theme background.
    public var backgroundColor: NSColor?

    // MARK: Coalescing observers (replace NSLock + DispatchQueue.main.async)

    @ObservationIgnored
    private let scrollbarObserver: any TerminalScrollbarObserving

    @ObservationIgnored
    private let renderObserver: any TerminalRenderObserving

    @ObservationIgnored
    private var scrollbarConsumerTask: Task<Void, Never>?

    @ObservationIgnored
    private var renderConsumerTask: Task<Void, Never>?

    // MARK: Scrollbar pending slot (synchronously drainable)
    //
    // The AsyncStream coalesces the high-frequency wakeups, but the copy-mode
    // viewport-jump path needs a *synchronous* "is there an un-flushed value, and
    // if so flush it now" operation (`flushPendingScrollbarIfAvailable()`). The
    // stream's buffered value is not synchronously peekable/drainable, so the
    // actual latest-pending value lives in this lock-guarded slot, faithfully
    // mirroring the legacy `_pendingScrollbar` + `_scrollbarLock`. The stream is
    // only the wakeup that schedules a main-actor drain; the slot is the single
    // source of truth for whether an un-drained value exists.
    @ObservationIgnored
    private let pendingScrollbarLock = NSLock()

    // `nonisolated(unsafe)` because `enqueueScrollbarUpdate` runs off the main
    // actor (the runtime I/O thread) and writes this slot; all access on both the
    // producer and the main-actor consumer is serialized by `pendingScrollbarLock`,
    // which is the manual safety the compiler cannot see. This is the same manual
    // lock discipline the legacy `_pendingScrollbar` + `_scrollbarLock` used.
    @ObservationIgnored
    private nonisolated(unsafe) var pendingScrollbar: GhosttyScrollbar?

    // MARK: Color-scheme dedup

    @ObservationIgnored
    private var appliedColorScheme: ghostty_color_scheme_e?

    // MARK: Debug log signature dedup

    @ObservationIgnored
    private var lastLoggedSurfaceBackgroundSignature: String?

    @ObservationIgnored
    private var lastLoggedWindowBackgroundSignature: String?

    // MARK: Surface-size bookkeeping

    @ObservationIgnored
    private var pendingSurfaceSize: CGSize?

    @ObservationIgnored
    private var deferredSurfaceSizeRetryQueued = false

    @ObservationIgnored
    private var needsSurfaceSizeRetryAfterMetalLayerRealizes = false

    @ObservationIgnored
    private var deferredSurfaceSizeNonMetalRetryCount = 0

    @ObservationIgnored
    private var lastDrawableSize: CGSize = .zero

#if DEBUG
    @ObservationIgnored
    private var lastSizeSkipSignature: String?
#endif

    private static let maxDeferredSurfaceSizeNonMetalRetryCount = 8

    // MARK: Init

    /// Creates a render coordinator with the coalescing observers.
    ///
    /// - Parameters:
    ///   - scrollbarObserver: The scrollbar coalescing seam.
    ///   - renderObserver: The rendered-frame coalescing seam.
    public init(
        scrollbarObserver: any TerminalScrollbarObserving = TerminalScrollbarObserver(),
        renderObserver: any TerminalRenderObserving = TerminalRenderObserver()
    ) {
        self.scrollbarObserver = scrollbarObserver
        self.renderObserver = renderObserver
        startConsumers()
    }

    // No `deinit`-time task cancellation: the consumer tasks capture `[weak
    // self]`, and the observers (which own the stream continuations) deallocate
    // with `self`, finishing the streams so each `for await` loop exits. A
    // nonisolated `deinit` cannot touch these `@MainActor` task handles anyway.

    private func startConsumers() {
        let scrollbarSnapshots = scrollbarObserver.snapshots
        scrollbarConsumerTask = Task { @MainActor [weak self] in
            // The stream value is only a wakeup; the authoritative latest value is
            // drained from the lock-guarded pending slot, exactly like the legacy
            // `DispatchQueue.main.async { flushPendingScrollbar() }` drained
            // `_pendingScrollbar` under `_scrollbarLock`.
            for await _ in scrollbarSnapshots {
                guard let self else { return }
                self.flushPendingScrollbar()
            }
        }
        let renderTicks = renderObserver.ticks
        renderConsumerTask = Task { @MainActor [weak self] in
            for await _ in renderTicks {
                guard let self else { return }
                self.applyRenderedFrameTick()
            }
        }
    }

    // MARK: Scrollbar coalescing

    /// Coalesces a high-frequency scrollbar update.
    ///
    /// The runtime action callback (which may fire thousands of times per second
    /// during bulk output) stores the latest value into the lock-guarded pending
    /// slot and offers a wakeup into the newest-wins stream; the main-actor
    /// consumer then drains the slot. Only the newest value survives, exactly as
    /// the legacy `_pendingScrollbar` overwrite did. `nonisolated` because the
    /// runtime callback may run off the main actor, exactly where the legacy
    /// `NSLock`-guarded enqueue ran; `pendingScrollbarLock` is the same lock
    /// primitive, and the continuation yield replaces the
    /// `DispatchQueue.main.async` flush schedule.
    public nonisolated func enqueueScrollbarUpdate(_ newValue: GhosttyScrollbar) {
        pendingScrollbarLock.lock()
        pendingScrollbar = newValue
        pendingScrollbarLock.unlock()
        scrollbarObserver.offer(newValue)
    }

    /// Drains and applies the pending scrollbar, if one is un-flushed.
    ///
    /// Faithful port of the legacy `flushPendingScrollbar()`: takes the pending
    /// value under the lock, clears the slot, and (only if a value was present)
    /// applies it to `scrollbar` and runs the host's post body (the
    /// scrollbar notification + copy-mode viewport-jump cursor sync).
    private func flushPendingScrollbar() {
        pendingScrollbarLock.lock()
        let pending = pendingScrollbar
        pendingScrollbar = nil
        pendingScrollbarLock.unlock()

        guard let pending else { return }
        scrollbar = pending
        host?.renderHostDidFlushScrollbar(pending)
    }

    /// Flushes any pending scrollbar synchronously if one is available.
    ///
    /// Faithful port of the legacy `flushPendingScrollbarIfAvailable()` used by
    /// the copy-mode viewport-jump path: returns `true` ONLY when an un-flushed
    /// value sits in the pending slot, and in that case synchronously flushes it
    /// (applying `scrollbar` and running the host's `finishViewportJumpCursorSync`
    /// post body). Returns `false` when nothing is pending, which is the signal
    /// the copy-mode controller uses to fall through to its line-delta fallback.
    @discardableResult
    public func flushPendingScrollbarIfAvailable() -> Bool {
        pendingScrollbarLock.lock()
        let hasPending = pendingScrollbar != nil
        pendingScrollbarLock.unlock()

        guard hasPending else { return false }
        flushPendingScrollbar()
        return true
    }

    // MARK: Rendered-frame coalescing

    /// Coalesces a rendered-frame wakeup.
    ///
    /// `nonisolated` so the off-main render path can offer without a main-actor
    /// hop. The enqueue-time render-demand gate is applied by the host before
    /// calling this (the legacy `enqueueRenderedFrameUpdate()` read the
    /// nonisolated demand atomic inline); the consumer re-checks the demand on
    /// the main actor in ``applyRenderedFrameTick()`` before posting.
    public nonisolated func enqueueRenderedFrameUpdate() {
        renderObserver.offer()
    }

    private func applyRenderedFrameTick() {
        guard host?.renderHostIsRenderDemandActive() == true else { return }
        host?.renderHostPostRenderedFrame()
    }

    // MARK: Appearance

    /// Applies the surface background fill, owning the per-surface override and
    /// the debug-log signature dedup, delegating the app-coupled composition to
    /// the host.
    public func applySurfaceBackground() {
        lastLoggedSurfaceBackgroundSignature = host?.renderHostApplySurfaceBackgroundEffects(
            surfaceBackgroundColor: backgroundColor,
            lastLoggedSignature: lastLoggedSurfaceBackgroundSignature
        )
    }

    /// Applies the window-root backdrop when this surface is the active
    /// selection, owning the per-window debug-log signature dedup.
    public func applyWindowBackgroundIfActive() {
        guard let host else { return }
        guard host.renderHostShouldApplyWindowBackground() else { return }
        applySurfaceBackground()
        lastLoggedWindowBackgroundSignature = host.renderHostApplyWindowBackgroundEffects(
            surfaceBackgroundColor: backgroundColor,
            lastLoggedSignature: lastLoggedWindowBackgroundSignature
        )
    }

    /// Resets the applied color-scheme dedup so the next apply forces a write.
    ///
    /// The host calls this when attaching a different surface (the legacy
    /// `attachSurface` set `appliedColorScheme = nil`).
    public func resetAppliedColorScheme() {
        appliedColorScheme = nil
    }

    /// Applies the surface color scheme, deduping against the last applied scheme
    /// unless forced. Scheme resolution, the Ghostty C call, and logging are
    /// routed through the host.
    ///
    /// - Parameters:
    ///   - force: Forces a write even when the resolved scheme is unchanged.
    ///   - preferredColorScheme: An explicit preference, or `nil` to read the
    ///     app's effective terminal color-scheme preference via the host.
    public func applySurfaceColorScheme(
        force: Bool = false,
        preferredColorScheme: GhosttyConfig.ColorSchemePreference? = nil
    ) {
        guard let host, host.renderHostHasLiveSurface() else { return }
        let scheme = host.renderHostResolveGhosttyColorScheme(
            preferredColorScheme: preferredColorScheme
        )
        if !force, appliedColorScheme == scheme {
            host.renderHostLogColorScheme(scheme: scheme, force: force, applied: false)
            return
        }
        host.renderHostApplyGhosttyColorScheme(scheme)
        appliedColorScheme = scheme
        host.renderHostLogColorScheme(scheme: scheme, force: force, applied: true)
    }

    // MARK: Surface sizing

    /// The expected device-pixel size for a points size, using the host window's
    /// backing scale only (so ancestor canvas magnification never re-typesets the
    /// grid).
    public func expectedPixelSize(for pointsSize: CGSize) -> CGSize {
        let scale = max(1.0, host?.renderHostWindowBackingScaleFactor()
            ?? host?.renderHostLayerContentsScale() ?? 1.0)
        return CGSize(width: pointsSize.width * scale, height: pointsSize.height * scale)
    }

    /// Resolves the size to apply, preferring an explicit size, then current
    /// bounds, then the last pending size.
    public func resolvedSurfaceSize(preferred size: CGSize?) -> CGSize {
        if let size, size.width > 0, size.height > 0 {
            return size
        }
        let currentBounds = host?.renderHostBoundsSize() ?? .zero
        if currentBounds.width > 0, currentBounds.height > 0 {
            return currentBounds
        }
        if let pending = pendingSurfaceSize, pending.width > 0, pending.height > 0 {
            return pending
        }
        return currentBounds
    }

    /// Whether a surface resize should be deferred because a tab drag is in
    /// flight. Mirrors the legacy `shouldDeferSurfaceResizeForActiveDrag()`.
    ///
    /// The drag-event classification (the legacy `isDragResizeEvent`) lives in
    /// the host (`renderHostCurrentEventIsDragResize`) so the package never
    /// imports AppKit event enums; the deferral decision stays here.
    public func shouldDeferSurfaceResizeForActiveDrag() -> Bool {
        guard let host else { return false }
        if host.renderHostIsInteractiveGeometryResizeActive() {
            return false
        }
        guard host.renderHostHasTabDragPasteboardTypes() else { return false }
        return host.renderHostCurrentEventIsDragResize()
    }

    private func activeSurfaceResizeDeferralReason() -> String? {
        guard let host else { return nil }
        if host.renderHostInLiveResize() { return nil }
        return shouldDeferSurfaceResizeForActiveDrag() ? "tabDrag" : nil
    }

    /// Schedules a deferred retry of the surface-size update if one is not
    /// already queued and the host is in a window.
    @discardableResult
    public func scheduleDeferredSurfaceSizeRetryIfNeeded() -> Bool {
        guard let host, host.renderHostHasWindow(), !deferredSurfaceSizeRetryQueued else {
            return false
        }
        deferredSurfaceSizeRetryQueued = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.deferredSurfaceSizeRetryQueued = false
            _ = self.updateSurfaceSize()
        }
        return true
    }

    /// Re-runs the size update after the Metal layer realizes, if a retry was
    /// pending. Mirrors `reconcileSurfaceSizeAfterMetalLayerAttachIfNeeded()`.
    public func reconcileSurfaceSizeAfterMetalLayerAttachIfNeeded() {
        guard needsSurfaceSizeRetryAfterMetalLayerRealizes else { return }
        deferredSurfaceSizeNonMetalRetryCount = 0
        _ = updateSurfaceSize()
    }

    /// Pushes an explicit target size to the live surface.
    @discardableResult
    public func pushTargetSurfaceSize(_ size: CGSize) -> Bool {
        updateSurfaceSize(size: size)
    }

    /// Forces a full size reconciliation for the current bounds, keeping the
    /// drawable-size cache intact.
    @discardableResult
    public func forceRefreshSurface() -> Bool {
        updateSurfaceSize()
    }

    /// Reconciles the live `ghostty_surface_t` and Metal drawable with a target
    /// size, deferring while geometry is unusable or a drag is in flight.
    ///
    /// Faithful port of the legacy `updateSurfaceSize(size:)`. The coordinator
    /// owns all of the retry/defer/dedup bookkeeping; the host performs the
    /// AppKit layer mutations and the Ghostty resize.
    ///
    /// - Parameter size: An explicit target size, or `nil` to resolve from
    ///   bounds/pending.
    /// - Returns: Whether the layer or surface size changed.
    @discardableResult
    public func updateSurfaceSize(size: CGSize? = nil) -> Bool {
        guard let host, host.renderHostHasLiveSurface() else { return false }
        let size = resolvedSurfaceSize(preferred: size)
        guard size.width > 0 && size.height > 0 else {
            traceDefer(reason: "nonPositive", size: size, backingSize: nil, host: host)
            return false
        }
        if pendingSurfaceSize != size { deferredSurfaceSizeNonMetalRetryCount = 0 }
        pendingSurfaceSize = size
        if let deferralReason = activeSurfaceResizeDeferralReason() {
            scheduleDeferredSurfaceSizeRetryIfNeeded()
            traceDefer(reason: deferralReason, size: size, backingSize: nil, host: host)
            return false
        }

        guard host.renderHostHasWindow(),
              let backingScaleFactor = host.renderHostWindowBackingScaleFactor() else {
            traceDefer(reason: "noWindow", size: size, backingSize: nil, host: host)
            return false
        }

        // Derive pixel size from the window's backing scale, NOT from
        // convertToBacking: that conversion folds in ancestor transforms
        // (the canvas layout's NSScrollView magnification), which would
        // re-typeset the terminal at a shrunken pixel grid while zooming and
        // render duplicated rows. Terminals keep their logical pixel density
        // and scale visually under magnification; in split mode the two
        // formulas are identical.
        let backingSize = CGSize(
            width: size.width * max(1.0, backingScaleFactor),
            height: size.height * max(1.0, backingScaleFactor)
        )
        guard backingSize.width > 0, backingSize.height > 0 else {
            traceDefer(reason: "zeroBacking", size: size, backingSize: backingSize, host: host)
            return false
        }
        traceResume(size: size, backingSize: backingSize, host: host)
        let xScale = backingSize.width / size.width
        let yScale = backingSize.height / size.height
        let layerScale = max(1.0, backingScaleFactor)
        let drawablePixelSize = CGSize(
            width: floor(max(0, backingSize.width)),
            height: floor(max(0, backingSize.height))
        )
        var didChange = host.renderHostApplyLayerScale(layerScale)

        let drawableResult = host.renderHostApplyMetalDrawableSize(
            drawablePixelSize,
            lastDrawableSize: lastDrawableSize
        )
        if drawableResult.metalLayerRealized {
            deferredSurfaceSizeNonMetalRetryCount = 0
            needsSurfaceSizeRetryAfterMetalLayerRealizes = false
            if drawableResult.drawableSizeChanged { didChange = true }
            lastDrawableSize = drawableResult.newLastDrawableSize
        } else if deferredSurfaceSizeNonMetalRetryCount < Self.maxDeferredSurfaceSizeNonMetalRetryCount,
                  scheduleDeferredSurfaceSizeRetryIfNeeded() {
            needsSurfaceSizeRetryAfterMetalLayerRealizes = true
            deferredSurfaceSizeNonMetalRetryCount += 1
        }

        let surfaceSizeChanged = host.renderHostApplyTerminalSurfaceSize(
            width: size.width,
            height: size.height,
            xScale: xScale,
            yScale: yScale,
            layerScale: layerScale,
            backingSize: backingSize
        )
        return didChange || surfaceSizeChanged
    }

    // MARK: Debug size tracing (signature dedup owned here)

    private func traceDefer(
        reason: String,
        size: CGSize,
        backingSize: CGSize?,
        host: any TerminalSurfaceRenderHosting
    ) {
#if DEBUG
        let signatureSuffix: String
        switch reason {
        case "nonPositive":
            signatureSuffix = "\(Int(size.width))x\(Int(size.height))"
        case "noWindow":
            signatureSuffix = "\(Int(size.width))x\(Int(size.height))"
        case "zeroBacking":
            let backing = backingSize ?? .zero
            signatureSuffix = "\(Int(backing.width))x\(Int(backing.height))"
        default:
            signatureSuffix = "\(Int(size.width.rounded()))x\(Int(size.height.rounded()))"
        }
        let signature = "\(reason)-\(signatureSuffix)"
        if lastSizeSkipSignature != signature {
            host.renderHostTraceSurfaceSize(
                .deferred(
                    reason: reason,
                    size: size,
                    backingSize: backingSize,
                    inWindow: host.renderHostHasWindow()
                )
            )
            lastSizeSkipSignature = signature
        }
#endif
    }

    private func traceResume(
        size: CGSize,
        backingSize: CGSize,
        host: any TerminalSurfaceRenderHosting
    ) {
#if DEBUG
        if lastSizeSkipSignature != nil {
            host.renderHostTraceSurfaceSize(.resumed(size: size, backingSize: backingSize))
            lastSizeSkipSignature = nil
        }
#endif
    }

#if DEBUG
    /// The current pending surface size, for tests.
    public func debugPendingSurfaceSize() -> CGSize? { pendingSurfaceSize }

    /// The last applied drawable size, for tests.
    public func debugLastDrawableSizeForTesting() -> CGSize { lastDrawableSize }

    /// Whether a deferred size retry is queued, for tests.
    public func debugDeferredSurfaceSizeRetryQueuedForTesting() -> Bool {
        deferredSurfaceSizeRetryQueued
    }

    /// Drives a size update with an explicit size, for tests.
    @discardableResult
    public func debugUpdateSurfaceSizeForTesting(_ size: CGSize) -> Bool {
        updateSurfaceSize(size: size)
    }
#endif
}
