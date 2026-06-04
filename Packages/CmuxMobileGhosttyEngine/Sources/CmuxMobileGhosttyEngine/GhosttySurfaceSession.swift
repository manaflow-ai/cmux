public import Dispatch
public import Foundation

/// Owns one libghostty surface and is the single off-main owner of every
/// blocking `ghostty_surface_*` call (`process_output`, `render_now`,
/// `set_size`, `binding_action`, `read_text`, text input).
///
/// **Executor.** The actor runs on a dedicated `DispatchSerialQueue` rather
/// than the shared cooperative pool: libghostty's surface ops block on its
/// internal renderer/IO futex (a render waits on a free GPU frame; a mailbox
/// push can wait `.forever`). Parking those waits on the default executor
/// would starve every other actor in the process; a dedicated queue
/// reproduces the pre-actor `outputQueue` threading exactly — which is the
/// configuration that survived the 0x8BADF00D watchdog regressions
/// documented in the surface view.
///
/// **Ordering.** All state-mutating work enters through ``submit(_:)``, a
/// `nonisolated` synchronous yield into one `AsyncStream` consumed by a
/// single actor task. Calls made from the main actor are therefore executed
/// in exactly the order they were made — the same guarantee the serial
/// `DispatchQueue.async` enqueue order used to provide. (Plain actor methods
/// would not give this: two `Task { await session.x() }` hops may interleave.)
///
/// **Results** flow back on the surface's single
/// ``GhosttySurfaceHostEvent`` stream, so the hosting view applies them in
/// submission order from one main-actor consumer.
///
/// Lifecycle: create via
/// `GhosttyEngineService.makeSurfaceSession(...)`, end with ``shutdown()``,
/// which drains queued commands, frees the surface (the pre-actor
/// `GhosttySurfaceDisposer` semantics), and finishes the event stream.
public actor GhosttySurfaceSession {
    /// One unit of ordered surface work.
    public enum Command: Sendable {
        /// Feed PTY bytes through `process_output`.
        case output(Data)
        /// Run a keybinding action string (e.g. `set_font_size:12`,
        /// `scroll_to_bottom`).
        case bindingAction(String)
        /// Send committed text through the key-input path (test seam).
        case textInput(String)
        /// Send text through the paste path (test seam).
        case pasteText(String)
        /// Run one coalesced render pass and emit
        /// ``GhosttySurfaceHostEvent/renderCompleted``.
        case render
        /// Run a geometry pass and emit
        /// ``GhosttySurfaceHostEvent/geometryMeasured(_:)``.
        case geometry(GhosttySurfaceGeometryRequest)
    }

    // Dedicated serial executor; see the type doc. carve-out justification:
    // a queue (not the cooperative pool) must host libghostty's blocking
    // futex/GPU waits, exactly like the pre-actor `outputQueue`.
    private nonisolated let executorQueue: DispatchSerialQueue

    /// Routes this actor onto its dedicated serial queue.
    public nonisolated var unownedExecutor: UnownedSerialExecutor {
        executorQueue.asUnownedSerialExecutor()
    }

    private nonisolated let backend: any GhosttySurfaceControlling
    private nonisolated let events: AsyncStream<GhosttySurfaceHostEvent>.Continuation
    private nonisolated let commands: AsyncStream<Command>.Continuation
    private nonisolated let commandStream: AsyncStream<Command>

    /// Throttle stamp for the DEBUG accessibility-text read attached to
    /// ``GhosttySurfaceHostEvent/outputApplied(accessibilityText:)``.
    private var lastAccessibilityReadTime: ContinuousClock.Instant?

    /// Creates a session over `backend`, emitting results into `events`.
    ///
    /// - Parameters:
    ///   - backend: The surface operations implementation. Production code
    ///     passes a `GhosttyKitSurfaceBackend`; tests pass a scripted fake.
    ///   - events: The surface's host-event continuation (shared with the
    ///     C-callback bridge and the registry).
    ///   - qualityOfService: Executor queue QoS; defaults to
    ///     `.userInitiated` to match the pre-actor output queue.
    public init(
        backend: any GhosttySurfaceControlling,
        events: AsyncStream<GhosttySurfaceHostEvent>.Continuation,
        qualityOfService: DispatchQoS = .userInitiated
    ) {
        self.backend = backend
        self.events = events
        executorQueue = DispatchSerialQueue(
            label: "dev.cmux.GhosttySurfaceSession",
            qos: qualityOfService
        )
        (commandStream, commands) = AsyncStream.makeStream(of: Command.self)
        Task { await self.run() }
    }

    // MARK: - Ordered ingestion

    /// Enqueues one unit of surface work.
    ///
    /// Synchronous and `nonisolated` so main-actor callers keep strict
    /// submission ordering (see the type doc). After ``shutdown()`` further
    /// submissions are dropped.
    public nonisolated func submit(_ command: Command) {
        commands.yield(command)
    }

    /// Ends the session: drains queued commands, frees the surface, and
    /// finishes the event stream. Idempotent.
    public nonisolated func shutdown() {
        commands.finish()
    }

    // MARK: - Direct (main-thread-safe) passthroughs

    /// Sets keyboard focus. Direct cheap push, callable from the main actor —
    /// matches the pre-actor behavior where `set_focus` ran on main.
    public nonisolated func setFocus(_ focused: Bool) {
        backend.setFocus(focused)
    }

    /// Sets occlusion (`visible == false` makes draws skip). Direct cheap
    /// push, callable from the main actor — matches the pre-actor behavior.
    public nonisolated func setOcclusion(visible: Bool) {
        backend.setOcclusion(visible: visible)
    }

    /// Reads the IME caret point for cursor-overlay placement. Direct cheap
    /// read, callable per-frame from the main actor — matches the pre-actor
    /// behavior where `ghostty_surface_ime_point` ran on main.
    public nonisolated func imePoint() -> GhosttySurfaceIMEPoint {
        backend.imePoint()
    }

    // MARK: - Serialized reads

    /// Reads the surface text for `scope` on the session executor, so the
    /// read never contends libghostty's surface lock from the main thread.
    public func readText(_ scope: GhosttySurfaceTextScope) -> String? {
        backend.readText(scope)
    }

    /// Longest non-nil text across all scopes (test/diagnostics helper).
    public func longestReadableText() -> String? {
        GhosttySurfaceTextScope.allCases
            .compactMap { backend.readText($0) }
            .max { $0.utf8.count < $1.utf8.count }
    }

    /// Whether the surface's child process has exited.
    public func processExited() -> Bool {
        backend.processExited()
    }

    /// The current measured grid (serialized readback).
    public func measuredSize() -> GhosttySurfaceMeasuredSize {
        backend.measuredSize()
    }

    // MARK: - Command loop

    private func run() async {
        for await command in commandStream {
            switch command {
            case .output(let data):
                backend.processOutput(data)
                events.yield(.outputApplied(accessibilityText: throttledAccessibilityText()))
            case .bindingAction(let action):
                backend.performBindingAction(action)
            case .textInput(let text):
                backend.sendTextInput(text)
            case .pasteText(let text):
                backend.sendPasteText(text)
            case .render:
                backend.renderNow()
                events.yield(.renderCompleted)
            case .geometry(let request):
                events.yield(.geometryMeasured(measureGeometry(request)))
            }
        }
        backend.free()
        events.finish()
    }

    /// DEBUG-only throttled rendered-text read for the XCUITest accessibility
    /// label. Runs here on the session executor — already serialized with
    /// `process_output` — because reading it on the main thread contended the
    /// surface lock during render storms and wedged main on libghostty's
    /// futex until the watchdog killed the app.
    private func throttledAccessibilityText() -> String? {
        #if DEBUG
        let now = ContinuousClock.now
        if let last = lastAccessibilityReadTime, now - last < .milliseconds(500) {
            return nil
        }
        lastAccessibilityReadTime = now
        return GhosttySurfaceTextScope.allCases
            .compactMap { backend.readText($0) }
            .max { $0.utf8.count < $1.utf8.count }
        #else
        return nil
        #endif
    }

    /// The pre-actor `syncSurfaceGeometry` off-main block, verbatim in
    /// behavior: optional content-scale push, container-size push, natural
    /// readback, cell derivation, and the bounded pin-fit refinement.
    private func measureGeometry(_ request: GhosttySurfaceGeometryRequest) -> GhosttySurfaceGeometryMeasurement {
        if let contentScale = request.contentScaleToApply {
            backend.setContentScale(contentScale, contentScale)
        }
        let scale = request.scale
        let containerPxW = UInt32(max(1, Int((request.containerWidth * scale).rounded(.down))))
        let containerPxH = UInt32(max(1, Int((request.containerHeight * scale).rounded(.down))))
        backend.setSize(pixelWidth: containerPxW, pixelHeight: containerPxH)
        let measured = backend.measuredSize()

        var cellWidth = 0.0
        var cellHeight = 0.0
        if measured.columns > 0, measured.rows > 0, measured.pixelWidth > 0, measured.pixelHeight > 0 {
            cellWidth = Double(measured.pixelWidth) / Double(measured.columns)
            cellHeight = Double(measured.pixelHeight) / Double(measured.rows)
        }

        var pinnedSize: GhosttySurfacePinnedSize?
        if let pin = request.pin, pin.columns > 0, pin.rows > 0, cellWidth > 0, cellHeight > 0 {
            let fillsNaturalGrid = pin.columns >= measured.columns && pin.rows >= measured.rows
            let withinOneCell = (measured.columns - pin.columns) <= 1 && (measured.rows - pin.rows) <= 1
            let pinnedW = Double(pin.columns) * cellWidth / scale
            let pinnedH = Double(pin.rows) * cellHeight / scale
            if !fillsNaturalGrid, !withinOneCell,
               pinnedW + 0.5 < request.containerWidth || pinnedH + 0.5 < request.containerHeight {
                let fitted = fitSurfaceToGrid(
                    cols: pin.columns,
                    rows: pin.rows,
                    cellPixelWidth: cellWidth,
                    cellPixelHeight: cellHeight
                )
                pinnedSize = GhosttySurfacePinnedSize(
                    width: min(Double(fitted.pixelWidth) / scale, request.containerWidth),
                    height: min(Double(fitted.pixelHeight) / scale, request.containerHeight)
                )
            }
        }

        return GhosttySurfaceGeometryMeasurement(
            request: request,
            natural: measured,
            cellPixelWidth: cellWidth,
            cellPixelHeight: cellHeight,
            pinnedSize: pinnedSize
        )
    }

    /// Bounded pixel-nudge refinement landing the surface on the exact pinned
    /// grid: Ghostty subtracts padding and floors partial cells, so the
    /// reverse mapping is confirmed against Ghostty itself. The 8-step cap is
    /// load-bearing — an uncapped loop once burned the main thread for tens
    /// of thousands of iterations during a fast-zoom storm.
    private func fitSurfaceToGrid(
        cols: Int,
        rows: Int,
        cellPixelWidth: Double,
        cellPixelHeight: Double
    ) -> (pixelWidth: UInt32, pixelHeight: UInt32) {
        var requestedW = UInt32(max(1, Int((Double(cols) * cellPixelWidth).rounded(.down))))
        var requestedH = UInt32(max(1, Int((Double(rows) * cellPixelHeight).rounded(.down))))
        backend.setSize(pixelWidth: requestedW, pixelHeight: requestedH)
        var actual = backend.measuredSize()
        var steps = 0
        while steps < 8, actual.columns < cols || actual.rows < rows {
            if actual.columns < cols { requestedW += 1 }
            if actual.rows < rows { requestedH += 1 }
            backend.setSize(pixelWidth: requestedW, pixelHeight: requestedH)
            actual = backend.measuredSize()
            steps += 1
        }
        let width = actual.pixelWidth > 0 ? UInt32(actual.pixelWidth) : requestedW
        let height = actual.pixelHeight > 0 ? UInt32(actual.pixelHeight) : requestedH
        return (width, height)
    }
}
