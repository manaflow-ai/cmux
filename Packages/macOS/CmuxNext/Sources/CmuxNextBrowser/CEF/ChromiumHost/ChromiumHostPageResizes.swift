import Darwin

/// Host mode's page resizes (task 052 of plans/cmux-next/chrome-parity/p01-process.md; the wire is
/// ChromiumHost/src/host_resize.h).
///
/// A hosted page's view changes size in a main-thread turn of cmux; its Chromium window lives in the
/// Chromium Host. Each size change goes to the host as one ordered `kOpPageResize`, with nothing that
/// waits for it.
final class ChromiumHostPageResizes {
    /// What the resizes did since this was made.
    struct Stats: Equatable, Sendable {
        /// Resizes sent: one per page view whose size changed.
        var resizes = 0
        /// The longest main-thread time one resize took here, in nanoseconds.
        var maxResizeNanoseconds: UInt64 = 0
    }

    private(set) var stats = Stats()

    private let wire: any ChromiumHostPageResizeWire
    private let now: () -> UInt64
    /// The size each page view was last sent, by its wire token.
    private var sentSizes: [UInt64: Size] = [:]

    private struct Size: Equatable {
        let width: Int32
        let height: Int32
    }

    /// - Parameters:
    ///   - wire: Where the resizes go (the remote shim's `cmux_remote_shim_page_resize`).
    ///   - now: Monotonic nanoseconds (`CLOCK_UPTIME_RAW`) for ``Stats/maxResizeNanoseconds``.
    init(wire: any ChromiumHostPageResizeWire,
         now: @escaping () -> UInt64 = { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }) {
        self.wire = wire
        self.now = now
    }

    /// Page view `view` (its wire token) is `geometry` now: sends its size when it changed. In the
    /// turn of the frame change. `resend` sends an unchanged size again: for a page window the host
    /// may have opened since (``CEFPaneHost/showHostedContext(of:)``).
    func resize(view: UInt64, geometry: ChromiumHostGeometry, resend: Bool = false) { // perf-hot: 0.1ms cef-geometry (each size change of a hosted page view)
        let start = now()
        defer { stats.maxResizeNanoseconds = max(stats.maxResizeNanoseconds, now() &- start) }
        let size = Size(width: geometry.width, height: geometry.height)
        guard view != 0, size.width >= 1, size.height >= 1 else { return }
        guard sentSizes[view] != size || resend else { return }
        guard wire.resize(view: view, width: size.width, height: size.height) else { return }
        sentSizes[view] = size
        stats.resizes += 1
    }
}

/// Where the page resizes go: the remote shim (``ChromiumHostRemoteResizeWire``) or a test recorder.
protocol ChromiumHostPageResizeWire: AnyObject {
    /// Sends one resize: false when it was not sent (no host attached), and the size goes again on
    /// the next change.
    func resize(view: UInt64, width: Int32, height: Int32) -> Bool
}
