import AppKit
import Darwin

/// Host mode's page resizes and their Core Animation fence (task 052 of
/// plans/cmux-next/chrome-parity/p01-process.md; the wire is ChromiumHost/src/host_resize.h).
///
/// A hosted page's view changes size in a main-thread turn of cmux; its Chromium window lives in the
/// Chromium Host. Each size change goes to the host as one ordered `kOpPageResize`. With the feature
/// `chromiumHostResizeFence`, the turn's Core Animation commit of the view's window waits on a fence
/// port of that window's context until the page's commit at the new size joins it, so pane and page
/// change size in one WindowServer update and the page never shows stretched or clipped against its
/// pane. That is WebKit's resize of a web view: the UI process makes the fence on its window's
/// context (`TiledCoreAnimationDrawingAreaProxy::createFence`,
/// Source/WebKit/UIProcess/mac/TiledCoreAnimationDrawingAreaProxy.mm) and the web process's commit at
/// the new size joins it (`TiledCoreAnimationDrawingArea::updateGeometry`).
///
/// One fence per window per turn: every page that turn resizes sends its own copy of the right with
/// its resize, and cmux drops its own right once the turn's transaction committed. The main thread
/// never waits on a fence: the WindowServer holds the commit, for ``CEFResizeSyncDeadline/fenceFrames``
/// display frame at most from that commit. The fork drops its right after the page's commit at the new
/// size or one frame after it joined. A host that has not answered within a frame (a busy or hung UI
/// thread, its right still in the inbox) has every fence of the window ended by cmux; so has one that
/// joined after the commit, one frame after the commit, unless a newer turn of the window holds a fence
/// (that turn's commit comes later, and its own answer bounds both). The commit then shows the page's
/// last frame on the page view's background (``ChromiumHostPageView/backgroundFill``), never a frame
/// the page did not draw. ``stats`` counts each outcome.
final class ChromiumHostResizeFence {
    /// What one resize went out as.
    enum Send: Equatable {
        /// Not sent (no host attached): the size is sent again on the next change.
        case notSent
        /// Sent with no fence: nothing waits for it.
        case unfenced
        /// Sent with the fence; the host's answer comes under `reply`.
        case fenced(reply: UInt32)
    }

    /// What the resizes did since this was made.
    struct Stats: Equatable, Sendable {
        /// Resizes sent: one per page view whose size changed.
        var resizes = 0
        /// Resizes that went with a fence.
        var fenced = 0
        /// Window turns whose commit waited on a fence.
        var fencedTurns = 0
        /// Fences the fork took (the host answered 1).
        var joined = 0
        /// Fences the host could not give the fork (answered 0): the commit waited for nothing.
        var refused = 0
        /// Fences with no answer within the deadline: cmux ended them, and the page showed its last frame.
        var late = 0
        /// Fences the host joined after their turn's commit: the fork's frame counts from its join, so the
        /// hold could pass one frame from the commit, and cmux ended the window's fences one frame after it.
        var cut = 0
        /// The longest main-thread time one resize took here (fence, hold, send), in nanoseconds.
        var maxResizeNanoseconds: UInt64 = 0
    }

    private(set) var stats = Stats()

    private let wire: any ChromiumHostPageResizeWire
    private let fences: (any ChromiumHostFenceMaking)?
    private let commits: any ChromiumHostCommitObserving
    private let deadlines: any ChromiumHostFenceDeadlines
    private let now: () -> UInt64
    /// The size each page view was last sent, by its wire token.
    private var sentSizes: [UInt64: Size] = [:]
    /// The fences of the turn in progress, until its commit.
    private var turn: Turn?
    /// Each window's newest held fence that still waits for its answer or its cut.
    private var newestFences: [ObjectIdentifier: ObjectIdentifier] = [:]

    private struct Size: Equatable {
        let width: Int32
        let height: Int32
    }

    /// One turn's fences by window. The commit's completion holds it, so cmux's rights go at the
    /// commit even when this coordinator went first (the host ended in the turn).
    private final class Turn {
        var fences: [ObjectIdentifier: ChromiumHostFence] = [:]
        /// The completion that releases the fences is registered.
        var endsAtCommit = false
        /// When the turn's transaction committed (`now`); nil before.
        var committedAt: UInt64?
    }

    /// - Parameters:
    ///   - wire: Where the resizes go (the remote shim's `cmux_remote_shim_page_resize`).
    ///   - fences: Makes a window's fence; nil sends every resize unfenced (the feature off).
    ///   - commits: Runs work once the turn's Core Animation transaction committed.
    ///   - deadlines: Runs the cut of a hold one frame after its turn's commit.
    ///   - now: Monotonic nanoseconds (`CLOCK_UPTIME_RAW`): the commit time and ``Stats/maxResizeNanoseconds``.
    init(wire: any ChromiumHostPageResizeWire, fences: (any ChromiumHostFenceMaking)?,
         commits: any ChromiumHostCommitObserving = ChromiumHostTransactionCommits(),
         deadlines: any ChromiumHostFenceDeadlines,
         now: @escaping () -> UInt64 = { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }) {
        self.wire = wire
        self.fences = fences
        self.commits = commits
        self.deadlines = deadlines
        self.now = now
    }

    /// Page view `view` (its wire token), showing `browser`, is `geometry` now: sends its size when it
    /// changed, with this turn's fence of `window` when there is one. In the turn of the frame change.
    /// `resend` sends an unchanged size again, unfenced (it changes no frame the host has): for a page
    /// window the host may have opened since (``CEFPaneHost/showHostedContext(of:)``).
    func resize(view: UInt64, browser: Int32, geometry: ChromiumHostGeometry, in window: NSWindow?, // perf-hot: 0.1ms cef-geometry (each size change of a hosted page view)
                resend: Bool = false) {
        let start = now()
        defer { stats.maxResizeNanoseconds = max(stats.maxResizeNanoseconds, now() &- start) }
        let size = Size(width: geometry.width, height: geometry.height)
        guard view != 0, size.width >= 1, size.height >= 1 else { return }
        let changed = sentSizes[view] != size
        guard changed || resend else { return }
        let fenced = changed ? window.flatMap { turnFence(of: $0) } : nil
        // After the send and the hold: a commit that completes at once releases cmux's right then.
        defer { if let fenced { endAtCommit(fenced.turn) } }
        let sent = wire.resize(view: view, browser: browser, width: size.width, height: size.height,
                               fence: fenced?.fence.port ?? 0, deadlineFrames: CEFResizeSyncDeadline.fenceFrames)
        guard sent != .notSent else { return }
        sentSizes[view] = size
        stats.resizes += 1
        guard case .fenced(let reply) = sent, let fenced, let window else { return }
        stats.fenced += 1
        let key = ObjectIdentifier(window)
        let fence = fenced.fence
        let fencedTurn = fenced.turn
        if fence.hold() {
            stats.fencedTurns += 1
            newestFences[key] = ObjectIdentifier(fence)
        }
        let frame = CEFResizeSyncDeadline.fenceDeadline(refreshInterval: window.screen?.minimumRefreshInterval ?? 0)
        wire.whenAnswered(reply, within: frame) { [weak self] joined in
            if joined == nil { fence.endAll() }  // a late host: the page shows its last frame
            guard let self else { return }
            switch joined {
            case true?:
                stats.joined += 1
                cutHold(of: fence, in: key, turn: fencedTurn, frame: frame)
            case false?:
                stats.refused += 1
                settled(fence, in: key)
            case nil:
                stats.late += 1
                settled(fence, in: key)
            }
        }
    }

    /// `window`'s fence for this turn, made on its first resize of the turn; nil when none can be made.
    private func turnFence(of window: NSWindow) -> (fence: ChromiumHostFence, turn: Turn)? {
        guard let fences else { return nil }
        let key = ObjectIdentifier(window)
        let current = turn ?? Turn()
        if let fence = current.fences[key] { return (fence, current) }
        guard let fence = fences.makeFence(for: window) else { return nil }
        current.fences[key] = fence
        turn = current
        return (fence, current)
    }

    /// Releases the turn's own rights once its transaction committed, and notes when.
    private func endAtCommit(_ current: Turn) {
        guard !current.endsAtCommit else { return }
        current.endsAtCommit = true
        let now = self.now
        commits.afterCommit { [weak self] in
            current.committedAt = now()
            // The host's copies hold each fence until the fork drops them; cmux's own rights go now.
            for fence in current.fences.values { fence.releaseOwnRight() }
            if self?.turn === current { self?.turn = nil }
        }
    }

    /// The fork took `fence`; its frame counts from its join. Joined before the turn's commit, the hold
    /// ends within one frame of that commit. Joined after it, cmux ends the window's fences one frame
    /// after the commit, unless a newer turn of the window holds a fence: ending it would cut that turn's
    /// page short, and that turn's commit, after this one, bounds both.
    private func cutHold(of fence: ChromiumHostFence, in key: ObjectIdentifier, turn: Turn, frame: Duration) {
        guard let committedAt = turn.committedAt else { return settled(fence, in: key) }
        let due = committedAt &+ Self.nanoseconds(frame)
        let current = now()
        let delay: Duration = due > current ? .nanoseconds(Int64(clamping: due - current)) : .zero
        deadlines.after(delay) { [weak self] in
            guard let self else { return }
            let newest = newestFences[key].map { $0 == ObjectIdentifier(fence) } ?? true
            if newest, fence.endAll() { stats.cut += 1 }
            settled(fence, in: key)
        }
    }

    /// `fence` needs nothing more: it stops being its window's newest.
    private func settled(_ fence: ChromiumHostFence, in key: ObjectIdentifier) {
        if newestFences[key] == ObjectIdentifier(fence) { newestFences[key] = nil }
    }

    private static func nanoseconds(_ duration: Duration) -> UInt64 {
        let (seconds, attoseconds) = duration.components
        return UInt64(max(0, seconds)) &* 1_000_000_000 &+ UInt64(max(0, attoseconds) / 1_000_000_000)
    }
}

/// Makes a window's fence (``ChromiumHostContextFences`` in the app; tests pass a recorder).
protocol ChromiumHostFenceMaking {
    func makeFence(for window: NSWindow) -> ChromiumHostFence?
}

/// Where the page resizes go: the remote shim (``ChromiumHostRemoteResizeWire``) or a test recorder.
protocol ChromiumHostPageResizeWire: AnyObject {
    /// Sends one resize with a copy of `fence` (0: none).
    func resize(view: UInt64, browser: Int32, width: Int32, height: Int32, fence: mach_port_t,
                deadlineFrames: UInt32) -> ChromiumHostResizeFence.Send
    /// Calls `then` once: true when the fork took the fence, false when the host could not give it,
    /// nil when no answer came within `deadline`.
    func whenAnswered(_ reply: UInt32, within deadline: Duration, then: @escaping (Bool?) -> Void)
}
