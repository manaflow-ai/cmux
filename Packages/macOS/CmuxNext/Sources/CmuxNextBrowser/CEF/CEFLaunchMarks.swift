/// Chromium's start as launch marks: the App's receiver (``CEFLaunchMarkHooks``, given to the engine) puts them
/// in `debug.timings`, the startup trace and the bench's pipe, on the clock of every other launch mark,
/// so a launch reads when Chromium started against `first_window_frame_committed` and `startup_complete`.
/// Chrome records the same steps of its own start as one-shot startup metrics
/// (`components/startup_metric_utils/browser/startup_metric_utils.cc`: the browser main message loop's
/// start, `Startup.FirstWebContents.NonEmptyPaint3`). Each mark goes out once per process; this module
/// knows nothing of the App, it only calls the receiver.
///
/// The runtime owns the one value (`CEFRuntime.launchMarks`), on the main thread; only the framework
/// load's end comes off it, from the load task, which runs once.
nonisolated struct CEFLaunchMarks: Sendable {
    nonisolated enum Mark: String, CaseIterable, Sendable {
        /// The off-main load of the shim and the framework began (a preload, or a start's own load).
        case preloadStarted = "cef.preload_started"
        /// That load mapped the framework (sent from the load task, off main).
        case libraryLoaded = "cef.library_loaded"
        /// `CefInitialize` (in host mode, the attach's initialize) is about to run on main.
        case initializeStarted = "cef.initialize_started"
        /// It returned and Chromium runs.
        case initializeEnded = "cef.initialize_ended"
        /// A spare window's window came up (`CEFSpareWindow`).
        case spareWindowReady = "cef.spare_window_ready"
        /// The startup's Chromium page first painted content (`CEFFirstPaintBridge`, ``CEFRuntime/firstPagePainted(shown:)``),
        /// followed by ``CEFLaunchMarks/triggerMark(_:)`` naming what started Chromium.
        case firstPagePaint = "cef.first_page_paint"
    }

    /// Receives each mark's name, once, from any thread. Nil sends nothing (tests, a process that
    /// installs none); a mark that came before it is not sent later.
    var receiver: (@Sendable (String) -> Void)?
    private var sent: Set<Mark> = []

    /// Sends `mark` the first time; false when it went before.
    @discardableResult
    mutating func send(_ mark: Mark) -> Bool {
        guard sent.insert(mark).inserted else { return false }
        receiver?(mark.rawValue)
        return true
    }

    /// The first page paint and the trigger of the start it followed (`tab`, a warm start reason such
    /// as `restoredTab`, `newTabMenu` or `palette`, or `debugWindow`).
    mutating func firstPagePainted(trigger: String) {
        guard send(.firstPagePaint) else { return }
        receiver?(Self.triggerMark(trigger))
    }

    /// Ends ``Mark/firstPagePaint`` with no value, as Chrome's `FirstWebContentsProfiler` abandons its
    /// measurement (chrome/browser/metrics/first_web_contents_profiler.cc): no later paint sends it.
    mutating func abandonFirstPagePaint() {
        sent.insert(.firstPagePaint)
    }

    /// The load task's ``Mark/libraryLoaded`` send, taken on main when the one load task is made:
    /// the task runs once, so it sends once.
    mutating func libraryLoadedSend() -> @Sendable () -> Void {
        guard sent.insert(.libraryLoaded).inserted, let receiver else { return {} }
        return { receiver(Mark.libraryLoaded.rawValue) }
    }

    /// `cef.first_page_paint.trigger.<trigger>`.
    static func triggerMark(_ trigger: String) -> String { "\(Mark.firstPagePaint.rawValue).trigger.\(trigger)" }
}

/// What the App gives the engine for Chromium's launch marks (`CEFEngine.init`, `launchMarks`): where each
/// mark goes, and whether the launch still runs, which bounds the first page paint to the startup.
public struct CEFLaunchMarkHooks {
    /// Receives each mark's name, once per process, from any thread (the App's `DebugTimings.markLaunch`).
    public let receive: @Sendable (String) -> Void
    /// True until the launch completes (`startup_complete`): a page's first paint after it is not the
    /// startup's, and ``CEFLaunchMarks/Mark/firstPagePaint`` ends with no value.
    public let isStarting: () -> Bool

    /// - Parameters:
    ///   - receive: Receives each mark's name, from any thread.
    ///   - isStarting: Whether the launch still runs; read on main at a page's first paint.
    public init(receive: @escaping @Sendable (String) -> Void, isStarting: @escaping () -> Bool) {
        self.receive = receive
        self.isStarting = isStarting
    }
}
