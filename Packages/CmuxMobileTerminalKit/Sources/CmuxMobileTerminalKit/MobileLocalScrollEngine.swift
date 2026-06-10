import Foundation

/// Pure state machine for Stage 1 local (primary-screen) terminal scrolling on
/// the phone.
///
/// The phone mirrors the Mac's terminal in its own libghostty surface. In a
/// NORMAL (primary, non-alt) shell a swipe scrolls that locally-held history
/// with no per-frame RPC to the Mac; alt-screen behavior (TUIs) still forwards
/// every scroll so the program owns it. This type owns every gate and latch of
/// that decision so the UIKit view keeps only glue (gesture plumbing and the
/// libghostty C calls) and the logic is unit-testable.
///
/// One source of truth: the engine tracks only a *read-only scroll position*
/// into history the Mac already authored. It never owns content. Whenever the
/// Mac's live output could disagree with the local view position, the caller
/// asks ``consumeSnapRequest()`` and snaps the surface to the live bottom.
public struct MobileLocalScrollEngine: Sendable {
    /// Where a coalesced scroll flush should be routed.
    public enum FlushRoute: Equatable, Sendable {
        /// Forward the wheel delta to the Mac's real surface (alt screen, or no
        /// frame metadata yet so the local mirror holds no history).
        case forwardToMac
        /// Scroll the phone's own libghostty surface locally, no RPC.
        case scrollLocally
    }

    /// The result of applying one locally-routed scroll flush.
    public struct LocalScrollOutcome: Equatable, Sendable {
        /// The tracked offset (rows up from the live bottom) after the flush.
        public let upRows: Double
        /// True when this flush reached the top of locally-held history and the
        /// caller should issue ONE deeper-scrollback fetch (not one per flush).
        public let requestDeeperFetch: Bool
    }

    /// What an incoming frame's bytes require of the surface, decided just
    /// before the bytes apply (in `process_output` order).
    public struct SnapDecision: Equatable, Sendable {
        /// Snap the surface to the live bottom before applying the frame so its
        /// absolute-CUP paint lands in the viewport, not scrolled-up history.
        public let snapToLive: Bool
        /// When set, re-issue this cumulative upward delta after the frame
        /// applies: the frame is a deeper-scrollback fetch's snapshot and the
        /// reader should land back on the rows they were reading instead of
        /// being bounced to the bottom.
        public let restoreUpRows: Double?
    }

    /// Whether the mirrored surface's active screen is the alternate screen.
    /// Updated from each applied render-grid frame's `activeScreen`. Primary →
    /// scroll locally; alternate → forward to the Mac. Defaults to primary (a
    /// freshly-attached shell).
    public private(set) var isAlternateScreen = false

    /// True once any frame metadata has been received. Older Mac hosts (and the
    /// raw-byte compatibility path) never send render-grid metadata, so the
    /// phone holds no mirrored history at all; until the first meta arrives,
    /// every scroll keeps the legacy forward-to-Mac path instead of scrolling a
    /// history-less local mirror that the Mac would never see.
    public private(set) var hasReceivedFrameMeta = false

    /// How many scrollback rows above the live viewport the phone believes it
    /// currently holds in its local libghostty surface, from each full primary
    /// snapshot's `scrollbackRows`. Decides when a local scroll has reached the
    /// top of held history and a deeper-scrollback fetch is due.
    public private(set) var heldScrollbackRows = 0

    /// How many rows the phone is currently scrolled up from the live bottom in
    /// local (primary-screen) scroll mode, accumulated as a Double so sub-row
    /// per-flush residuals are not truncated away. 0 means "at live bottom".
    /// Read-only view position into Mac-authored history; never a second source
    /// of content. The snap-to-live path uses the exact `scroll_to_bottom`
    /// binding action, so this value only needs to be accurate enough to gate
    /// ``isLocalScrollActive`` and the deeper-fetch trigger.
    public private(set) var upRowsExact: Double = 0

    /// True while the user is reading local history (scrolled up) in primary
    /// mode. While set, an incoming live frame snaps to the bottom before
    /// applying (see ``consumeSnapRequest()``).
    public var isLocalScrollActive: Bool { upRowsExact >= 0.5 }

    /// Dedupe/retry latch: true while a deeper-scrollback fetch issued by this
    /// engine is believed outstanding, so a held pan at the history top fires
    /// ONE fetch, not one per flush. Cleared when a full snapshot arrives, and
    /// on a fresh pan `.began` as the retry point for a fetch that was dropped
    /// (e.g. by the shared replay in-flight guard) and will never produce a
    /// snapshot.
    private var fetchInFlight = false

    /// Classification latch: true from the moment a deeper-scrollback fetch is
    /// issued until the NEXT full snapshot arrives, so that snapshot is measured
    /// as the fetch's result (growth vs no-growth) even if the user started a
    /// new pan (which clears ``fetchInFlight`` for retry) before the
    /// slow-but-valid response landed. Cleared only by a full snapshot.
    private var fetchAwaitingSnapshot = false

    /// Scroll position (in the same units as ``upRowsExact``) to restore after a
    /// deeper-scrollback fetch's snapshot applies. A full snapshot rebuilds the
    /// local surface at the live bottom; without a restore, every history
    /// page-in would bounce the reader back to the bottom instead of leaving
    /// them on the rows they were reading. The fetch only grows history ABOVE
    /// the unchanged live bottom, so re-issuing the same cumulative upward delta
    /// lands on the same content rows. Armed when a fetch response is classified
    /// (``noteFullSnapshot(scrollbackRows:)``), consumed by
    /// ``consumeSnapRequest()`` so the snap, the snapshot apply, and the restore
    /// run back-to-back in `process_output` order. The caller delivers a frame's
    /// metadata and bytes as ONE ordered stream element (see
    /// `MobileTerminalOutputChunk`), so the arm and the consume happen within
    /// one synchronous apply: the restore is structurally consumed by the fetch
    /// snapshot's own apply, never by an interleaved live frame, and cannot go
    /// stale across a gesture. Cold-attach snapshots clear
    /// it (content may have changed wholesale; snapping to live is correct).
    private var pendingRestoreUpRows: Double?

    /// True once a deeper-scrollback fetch returned no additional history: the
    /// shell's whole scrollback is now held locally. Gates the fetch trigger so
    /// the view stops cleanly at the oldest known line instead of re-firing an
    /// RPC (and re-anchoring to the bottom) on every scroll-to-top. Cleared on
    /// genuine growth or a fresh cold-attach snapshot.
    private var historyFullyLoaded = false

    public init() {}

    /// Record the active screen from the latest applied frame. Flipping into
    /// the alternate screen mid-scroll immediately reverts routing to
    /// forwarding (alt scroll must reach the program). The local offset is NOT
    /// zeroed here: the surface may still be physically scrolled up, and only
    /// ``consumeSnapRequest()`` (which runs in `process_output` order when the
    /// next frame's bytes apply) may clear the tracked offset together with
    /// snapping the real surface. Zeroing it here would suppress that snap and
    /// let the alt program's CUP paints land in scrolled-up history.
    public mutating func noteActiveScreen(isAlternate: Bool) {
        hasReceivedFrameMeta = true
        isAlternateScreen = isAlternate
    }

    /// Record how much scrollback the local surface now holds, from a full
    /// primary snapshot. If this snapshot is the response to a deeper fetch and
    /// it carried no more history than before, the shell's whole scrollback is
    /// now held: mark it fully loaded so scroll-to-top stops cleanly instead of
    /// bouncing on a re-fetch. A genuinely larger snapshot (or a fresh cold
    /// attach that is not a fetch response) clears that ceiling.
    ///
    /// Deliberately does NOT touch ``upRowsExact``: the snapshot's bytes have
    /// not applied yet (the caller applies a frame's metadata immediately
    /// before its bytes), so zeroing the offset here would suppress the
    /// snap-to-live the caller dispatches (in `process_output` order) when
    /// those bytes apply. The offset is only cleared where the surface itself
    /// is snapped (``consumeSnapRequest()``), keeping the tracked position and
    /// the real surface position in step.
    public mutating func noteFullSnapshot(scrollbackRows: Int) {
        hasReceivedFrameMeta = true
        let newRows = max(0, scrollbackRows)
        if fetchAwaitingSnapshot {
            fetchAwaitingSnapshot = false
            // A fetch that did not grow history means we have reached the
            // oldest line the Mac can supply for now.
            historyFullyLoaded = newRows <= heldScrollbackRows
            // The reader was up in history when this fetch's snapshot was
            // built; arm a restore so the snapshot apply (which rebuilds the
            // surface at the live bottom) puts them back on the rows they were
            // reading. The live bottom is unchanged by a deeper fetch, so the
            // same cumulative upward delta lands on the same content rows;
            // libghostty clamps at the top of whatever it actually holds.
            pendingRestoreUpRows = isLocalScrollActive ? upRowsExact : nil
        } else {
            // Not a fetch response (cold attach / live full snapshot): history
            // may have changed underneath us, so re-open the ceiling and snap
            // to live rather than restoring a position into stale content.
            historyFullyLoaded = false
            pendingRestoreUpRows = nil
        }
        fetchInFlight = false
        heldScrollbackRows = newRows
    }

    /// A fresh swipe is the natural retry point for a deeper-scrollback fetch
    /// that never returned (e.g. dropped by the shared replay in-flight guard).
    /// Clears only the dedupe latch; the classification latch stays set so a
    /// slow-but-valid response is still measured as a fetch result rather than
    /// misread as a cold attach. A fetch that is genuinely still in flight is
    /// deduped by the shared replay guard downstream.
    public mutating func notePanBegan() {
        fetchInFlight = false
    }

    /// Where the next coalesced scroll flush should go. Alt screen forwards to
    /// the Mac (the program owns alt-screen scroll); so does the
    /// no-metadata-yet compatibility path (the local mirror holds no history
    /// and the Mac would never see the gesture otherwise). Primary scrolls
    /// locally.
    public var flushRoute: FlushRoute {
        (isAlternateScreen || !hasReceivedFrameMeta) ? .forwardToMac : .scrollLocally
    }

    /// Apply one locally-routed flush of `lines` (positive = up into history,
    /// matching the wheel-delta convention `ghostty_surface_mouse_scroll` uses
    /// on the Mac). Tracks the read-only view position as a Double (no
    /// per-flush rounding), clamped at 0 (live bottom). libghostty clamps at
    /// the top of the history it actually holds, so over-scrolling never shows
    /// blank rows; it just stops at the oldest held line until a deeper fetch
    /// lands.
    ///
    /// Reaching (or passing) the top of locally-held history while scrolling up
    /// requests ONE deeper-scrollback fetch (not per-flush): suppressed once a
    /// fetch returned no growth (history fully loaded) or while one is already
    /// outstanding, so a short-scrollback shell stops cleanly at the oldest
    /// line instead of bouncing to the bottom on every scroll-to-top.
    public mutating func applyLocalScroll(lines: Double) -> LocalScrollOutcome {
        let priorUpRows = upRowsExact
        let nextUpRows = max(0, priorUpRows + lines)
        upRowsExact = nextUpRows

        var requestDeeperFetch = false
        if lines > 0,
           nextUpRows >= Double(heldScrollbackRows),
           nextUpRows > priorUpRows,
           !historyFullyLoaded,
           !fetchInFlight {
            fetchInFlight = true
            fetchAwaitingSnapshot = true
            requestDeeperFetch = true
        }
        return LocalScrollOutcome(upRows: nextUpRows, requestDeeperFetch: requestDeeperFetch)
    }

    /// Decide what an incoming frame's bytes require of the surface, just
    /// before they apply. If the reader is scrolled up locally, the surface
    /// must snap to the live bottom first so the frame's absolute-CUP paint
    /// lands in the viewport; if a deeper-fetch restore is armed, the caller
    /// re-issues the preserved upward delta after the apply. Deliberately NOT
    /// gated on the active screen: a stale offset left by an alt-flip
    /// mid-scroll must still snap before the alt program's rows paint. This is
    /// the only place the tracked offset is cleared (or re-armed to the restore
    /// value), so it stays in step with the real surface position.
    public mutating func consumeSnapRequest() -> SnapDecision {
        guard isLocalScrollActive else {
            return SnapDecision(snapToLive: false, restoreUpRows: nil)
        }
        upRowsExact = 0
        var restore: Double?
        if let pending = pendingRestoreUpRows {
            pendingRestoreUpRows = nil
            restore = pending
            upRowsExact = pending
        }
        return SnapDecision(snapToLive: true, restoreUpRows: restore)
    }
}
