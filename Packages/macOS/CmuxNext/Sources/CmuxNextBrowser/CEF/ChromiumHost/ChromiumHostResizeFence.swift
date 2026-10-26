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
/// display frame at most. The fork drops its right after the page's commit at the new size or at that
/// deadline; a host that has not answered within it (a busy or hung UI thread, its right still in the
/// inbox) has every fence of the window ended by cmux, and the commit shows the page's last frame on
/// the page view's background (``ChromiumHostPageView/backgroundFill``), never a frame the page did
/// not draw. ``stats`` counts each outcome.
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
        /// The longest main-thread time one resize took here (fence, hold, send), in nanoseconds.
        var maxResizeNanoseconds: UInt64 = 0
    }

    private(set) var stats = Stats()

    private let wire: any ChromiumHostPageResizeWire
    private let fences: (any ChromiumHostFenceMaking)?
    private let commits: any ChromiumHostCommitObserving
    private let now: () -> UInt64
    /// The size each page view was last sent, by its wire token.
    private var sentSizes: [UInt64: Size] = [:]
    /// The fences of the turn in progress, until its commit.
    private var turn: Turn?

    private struct Size: Equatable {
        let width: Int32
        let height: Int32
    }

    /// One turn's fences by window. The commit's completion holds it, so cmux's rights go at the
    /// commit even when this coordinator went first (the host ended in the turn).
    private final class Turn {
        var fences: [ObjectIdentifier: ChromiumHostFence] = [:]
    }

    /// - Parameters:
    ///   - wire: Where the resizes go (the remote shim's `cmux_remote_shim_page_resize`).
    ///   - fences: Makes a window's fence; nil sends every resize unfenced (the feature off).
    ///   - commits: Runs work once the turn's Core Animation transaction committed.
    ///   - now: Monotonic nanoseconds, for ``Stats/maxResizeNanoseconds``.
    init(wire: any ChromiumHostPageResizeWire, fences: (any ChromiumHostFenceMaking)?,
         commits: any ChromiumHostCommitObserving = ChromiumHostTransactionCommits(),
         now: @escaping () -> UInt64 = { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }) {
        self.wire = wire
        self.fences = fences
        self.commits = commits
        self.now = now
    }

    /// Page view `view` (its wire token), showing `browser`, is `geometry` now: sends its size when it
    /// changed, with this turn's fence of `window` when there is one. In the turn of the frame change.
    func resize(view: UInt64, browser: Int32, geometry: ChromiumHostGeometry, in window: NSWindow?) { // perf-hot: 0.1ms cef-geometry (each size change of a hosted page view)
        let start = now()
        defer { stats.maxResizeNanoseconds = max(stats.maxResizeNanoseconds, now() &- start) }
        let size = Size(width: geometry.width, height: geometry.height)
        guard view != 0, size.width >= 1, size.height >= 1, sentSizes[view] != size else { return }
        let fence = window.flatMap { turnFence(of: $0) }
        let sent = wire.resize(view: view, browser: browser, width: size.width, height: size.height,
                               fence: fence?.port ?? 0, deadlineFrames: CEFResizeSyncDeadline.fenceFrames)
        guard sent != .notSent else { return }
        sentSizes[view] = size
        stats.resizes += 1
        guard case .fenced(let reply) = sent, let fence else { return }
        stats.fenced += 1
        if fence.hold() { stats.fencedTurns += 1 }
        let deadline = CEFResizeSyncDeadline.fenceDeadline(refreshInterval: window?.screen?.minimumRefreshInterval ?? 0)
        wire.whenAnswered(reply, within: deadline) { [weak self] joined in
            switch joined {
            case true?: self?.stats.joined += 1
            case false?: self?.stats.refused += 1
            case nil:
                self?.stats.late += 1
                fence.endAll()
            }
        }
    }

    /// `window`'s fence for this turn, made on its first resize of the turn; nil when none can be made.
    private func turnFence(of window: NSWindow) -> ChromiumHostFence? {
        guard let fences else { return nil }
        let key = ObjectIdentifier(window)
        if let fence = turn?.fences[key] { return fence }
        guard let fence = fences.makeFence(for: window) else { return nil }
        let current: Turn
        if let turn {
            current = turn
        } else {
            current = Turn()
            turn = current
            commits.afterCommit { [weak self] in
                // The host's copies hold each fence until the fork drops them; cmux's own rights go now.
                for fence in current.fences.values { fence.releaseOwnRight() }
                if self?.turn === current { self?.turn = nil }
            }
        }
        current.fences[key] = fence
        return fence
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
