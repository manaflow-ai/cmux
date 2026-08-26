import CMUXMobileCore
import Dispatch
import Foundation

@MainActor
final class MobileBrowserStreamSession {
    private enum DirtyCause {
        case pageSignal
        case inputReplay
    }

    let id = UUID()
    let connectionID: UUID
    let panelID: UUID

    private let panel: BrowserPanel
    private let connection: MobileHostConnection
    private let clock: any MobileBrowserStreamClock
    private let frameEncoder: MobileBrowserFrameEncoder
    private let wireEncoder = MobileBrowserWireEncoder()
    private let onEnded: @MainActor (UUID) -> Void
    private let signalHandlerID = UUID()

    private var pacing = MobileBrowserStreamPacing()
    private var editableFocused = false
    private var lastState: MobileBrowserStateEvent?
    private var driveTask: Task<Void, Never>?
    private var deadlineTask: Task<Void, Never>?
    private var stateTask: Task<Void, Never>?
    private var dialogEventTask: Task<Void, Never>?
    private var isDriving = false
    private var needsDrive = false
    private var isStopped = false
    /// Whether at least one synchronized (post-commit) capture succeeded for
    /// the current web view. Until then every capture waits for WebKit's next
    /// committed render, because an unsynchronized snapshot of a freshly
    /// (re)hosted or still-loading web view is a blank white bitmap.
    private var hasCapturedCommittedFrame = false
    private var hasRecordedFirstDeliveredFrame = false
    private var synchronizedFirstCaptureFailures = 0

    /// Bound on the synchronized first capture so an occluded render host
    /// cannot wedge the stream; expiry falls back through the retry path.
    private static let firstCaptureTimeout: TimeInterval = 1.0
    /// Bound on every other capture; a synchronized settle snapshot waits on
    /// WebKit's next commit, which an occluded host may never produce.
    private static let captureTimeout: TimeInterval = 2.0
    /// Synchronized first-capture attempts before degrading to unsynchronized.
    private static let maximumSynchronizedFirstCaptureFailures = 3
    /// Quiet interval before an idle stream emits one reconciliation frame.
    private static let idleReconcileInterval: TimeInterval = 10.0

    init(
        connectionID: UUID,
        panel: BrowserPanel,
        connection: MobileHostConnection,
        clock: any MobileBrowserStreamClock = MobileBrowserContinuousClock(),
        frameEncoder: MobileBrowserFrameEncoder = MobileBrowserFrameEncoder(),
        onEnded: @escaping @MainActor (UUID) -> Void
    ) {
        self.connectionID = connectionID
        self.panelID = panel.id
        self.panel = panel
        self.connection = connection
        self.clock = clock
        self.frameEncoder = frameEncoder
        self.onEnded = onEnded
    }

    func start() {
        guard !isStopped else { return }
        panel.addMobileBrowserStreamSignalHandler(id: signalHandlerID) { [weak self] signal in
            self?.handle(signal)
        }
        pacing.noteDirty(at: clock.now)
        emitStateImmediately()
        requestDrive()
    }

    func acknowledge(sequence: UInt64) {
        guard !isStopped else { return }
        pacing.acknowledge(sequence: sequence)
        requestDrive()
    }

    func noteInputReplayed() {
        noteDirty(cause: .inputReplay)
    }

    func stop(sendClosed: Bool) async {
        guard !isStopped else { return }
        isStopped = true
        deadlineTask?.cancel()
        deadlineTask = nil
        stateTask?.cancel()
        stateTask = nil
        dialogEventTask?.cancel()
        dialogEventTask = nil
        driveTask?.cancel()
        driveTask = nil
        panel.removeMobileBrowserStreamSignalHandler(id: signalHandlerID)
        if sendClosed,
           let payload = wireEncoder.object(MobileBrowserClosedEvent(panelID: panelID.uuidString)) {
            _ = await connection.sendEvent(topic: "browser.closed", payload: payload)
        }
    }

    private func handle(_ signal: MobileBrowserPanelNativeSignal) {
        guard !isStopped else { return }
        switch signal {
        case let .dirty(focused):
            if let focused, editableFocused != focused {
                editableFocused = focused
                MobileHostDiagnostics.hostDiagnosticLog.record(DiagnosticEvent(
                    .browserEditableFocus,
                    a: focused ? 1 : 0,
                    b: 3,
                    c: TerminalController.mobileBrowserPanelCorrelation(panelID)
                ))
                scheduleStateEmission()
            }
            noteDirty()
        case .stateChanged:
            scheduleStateEmission()
        case .webViewReplaced:
            hasCapturedCommittedFrame = false
            synchronizedFirstCaptureFailures = 0
            noteDirty()
            emitStateImmediately()
        case let .dialog(dialog):
            emitDialog(dialog)
        case let .dialogResolved(resolved):
            emitDialogResolved(resolved)
        case .closed:
            Task { @MainActor [weak self] in
                await self?.panelDidClose()
            }
        }
    }

    private func noteDirty(cause: DirtyCause = .pageSignal) {
        guard !isStopped else { return }
        switch cause {
        case .pageSignal:
            pacing.noteDirty(at: clock.now)
        case .inputReplay:
            pacing.noteInputReplayed(at: clock.now)
        }
        requestDrive()
    }

    private func emitDialog(_ dialog: MobileBrowserDialogEvent) {
        guard !isStopped, let payload = wireEncoder.object(dialog) else { return }
        enqueueDialogEvent(topic: "browser.dialog", payload: payload)
    }

    private func emitDialogResolved(_ resolved: MobileBrowserDialogResolvedEvent) {
        guard !isStopped, let payload = wireEncoder.object(resolved) else { return }
        enqueueDialogEvent(topic: "browser.dialog.resolved", payload: payload)
    }

    private func enqueueDialogEvent(topic: String, payload: [String: Any]) {
        let previous = dialogEventTask
        dialogEventTask = Task { @MainActor [weak self] in
            if let previous { await previous.value }
            guard let self, !isStopped, !Task.isCancelled else { return }
            _ = await connection.sendEvent(topic: topic, payload: payload)
        }
    }

    private func panelDidClose() async {
        guard !isStopped else { return }
        await dialogEventTask?.value
        await stop(sendClosed: true)
        onEnded(id)
    }

    private func requestDrive() {
        guard !isStopped else { return }
        needsDrive = true
        deadlineTask?.cancel()
        deadlineTask = nil
        guard !isDriving else { return }
        isDriving = true
        driveTask = Task { @MainActor [weak self] in
            await self?.drive()
        }
    }

    private func drive() async {
        defer {
            isDriving = false
            driveTask = nil
            if needsDrive, !isStopped {
                requestDrive()
            }
        }
        while !isStopped, !Task.isCancelled {
            needsDrive = false
            switch pacing.decision(at: clock.now) {
            case let .captureJPEG(generation):
                guard await captureAndEmit(format: .jpeg, dirtyGeneration: generation) else {
                    scheduleDeadline(after: 0.100)
                    return
                }
            case let .capturePNG(generation):
                guard await captureAndEmit(format: .png, dirtyGeneration: generation) else {
                    scheduleDeadline(after: 0.100)
                    return
                }
            case let .wait(interval):
                scheduleDeadline(after: interval)
                return
            case .flowControlled:
                // Pacing converts a full window into bounded `.wait`s and then
                // ack-stall recovery, so this is defensive: re-check rather
                // than park with no deadline armed.
                scheduleDeadline(after: pacing.ackStallTimeout)
                return
            case .idle:
                scheduleIdleReconciliation()
                return
            }
        }
    }

    private func captureAndEmit(
        format: MobileBrowserFrameFormat,
        dirtyGeneration: UInt64
    ) async -> Bool {
        // Captured once so the snapshot, its measured page size, and the
        // committed-frame bookkeeping all describe the SAME web view even
        // if the panel replaces its web view while the capture awaits.
        let capturedWebView = panel.webView
        do {
            let pageSize = capturedWebView.bounds.size
            // Continuous JPEG frames drive motion (scroll, drag, animation). The
            // active dirty loop must not block each snapshot on a synchronized
            // screen-update cycle. `false` captures the currently committed render
            // without that wait, while the rare, correctness-critical lossless PNG
            // settle frame keeps the synchronized path. The FIRST capture for a
            // web view is always synchronized: it races the view's first commit
            // after offscreen rehosting or replacement, and the unsynchronized
            // snapshot of that state is a blank white bitmap the subscriber
            // would display until the next dirty signal. Bounded by a timeout
            // and a fallback so an occluded host cannot wedge the stream.
            let forceSynchronizedFirstCapture = !hasCapturedCommittedFrame
                && synchronizedFirstCaptureFailures < Self.maximumSynchronizedFirstCaptureFailures
            let waitForScreenUpdate = (format == .png) || forceSynchronizedFirstCapture
            #if DEBUG
            let captureStart = DispatchTime.now()
            #endif
            let image = try await BrowserScreenshotWebViewSnapshotter.captureVisibleViewport(
                from: capturedWebView,
                afterScreenUpdates: waitForScreenUpdate,
                timeout: forceSynchronizedFirstCapture ? Self.firstCaptureTimeout : Self.captureTimeout
            )
            guard !isStopped, !Task.isCancelled else { return false }
            // A capture that raced a web view replacement proves nothing about
            // the panel's CURRENT web view: its first synchronized capture is
            // still owed, or the next first frame is the blank bitmap again.
            if waitForScreenUpdate, panel.webView === capturedWebView {
                hasCapturedCommittedFrame = true
                synchronizedFirstCaptureFailures = 0
            }
            panel.updateMobileBrowserStreamMirror(image)
            #if DEBUG
            let encodeStart = DispatchTime.now()
            #endif
            let encoded = try frameEncoder.encode(image, format: format)
            #if DEBUG
            let encodeEnd = DispatchTime.now()
            let captureMs = Double(encodeStart.uptimeNanoseconds &- captureStart.uptimeNanoseconds) / 1_000_000
            let encodeMs = Double(encodeEnd.uptimeNanoseconds &- encodeStart.uptimeNanoseconds) / 1_000_000
            cmuxDebugLog(
                "browser.frame.capture fmt=\(format) wait=\(waitForScreenUpdate) "
                    + "capMs=\(String(format: "%.1f", captureMs)) "
                    + "encMs=\(String(format: "%.1f", encodeMs)) "
                    + "bytes=\(encoded.data.count) px=\(encoded.pixelWidth)x\(encoded.pixelHeight) "
                    + "unacked=\(pacing.unackedSequences.count)"
            )
            #endif
            guard let sequence = pacing.recordEmission(
                format: format,
                observedDirtyGeneration: dirtyGeneration,
                at: clock.now
            ) else { return true }
            let event = MobileBrowserFrameEvent(
                panelID: panelID.uuidString,
                sequence: sequence,
                format: encoded.format,
                pageWidth: max(0, Double(pageSize.width)),
                pageHeight: max(0, Double(pageSize.height)),
                pixelWidth: encoded.pixelWidth,
                pixelHeight: encoded.pixelHeight,
                dataBase64: encoded.data.base64EncodedString()
            )
            guard let payload = wireEncoder.object(event) else {
                pacing.acknowledge(sequence: sequence)
                pacing.noteDirty(at: clock.now)
                return false
            }
            let delivered = await connection.sendEvent(topic: "browser.frame", payload: payload)
            if !delivered {
                pacing.acknowledge(sequence: sequence)
                pacing.noteDirty(at: clock.now)
            } else if !hasRecordedFirstDeliveredFrame {
                // The first-frame stage means the phone actually received a
                // frame: record it once per session, after delivery succeeds,
                // never for the capture alone.
                hasRecordedFirstDeliveredFrame = true
                MobileHostDiagnostics.hostDiagnosticLog.record(DiagnosticEvent(
                    .browserStreamLifecycle,
                    a: 4,
                    c: TerminalController.mobileBrowserPanelCorrelation(panelID)
                ))
            }
            return delivered
        } catch is CancellationError {
            return false
        } catch {
            // A stale capture's failure must not consume the replacement web
            // view's bounded synchronized-first-capture attempts.
            if !hasCapturedCommittedFrame, panel.webView === capturedWebView {
                synchronizedFirstCaptureFailures += 1
            }
            return false
        }
    }

    private func scheduleDeadline(after interval: TimeInterval) {
        guard !isStopped else { return }
        deadlineTask?.cancel()
        let clock = clock
        deadlineTask = Task { @MainActor [weak self, clock] in
            do {
                // Bounded, cancellable cadence/settle deadline; new signals cancel it.
                try await clock.sleep(for: max(0, interval))
                guard !Task.isCancelled else { return }
                self?.requestDrive()
            } catch {}
        }
    }

    /// Schedules one lossless reconciliation frame after a quiet interval.
    ///
    /// An idle stream's correctness otherwise hangs entirely on page-driven
    /// dirty signals, which are silently lost when WebKit suspends
    /// `requestAnimationFrame` for the occluded offscreen host. This bounds
    /// how long the phone can display a stale (or blank first) frame to
    /// `idleReconcileInterval`. Any real dirty signal cancels it via
    /// `requestDrive`, and a fresh one is armed when the stream idles again.
    private func scheduleIdleReconciliation() {
        guard !isStopped else { return }
        deadlineTask?.cancel()
        let clock = clock
        deadlineTask = Task { @MainActor [weak self, clock] in
            do {
                try await clock.sleep(for: Self.idleReconcileInterval)
                guard !Task.isCancelled, let self, !self.isStopped else { return }
                self.pacing.requestSettleReconciliation()
                self.requestDrive()
            } catch {}
        }
    }

    private func scheduleStateEmission() {
        guard !isStopped else { return }
        stateTask?.cancel()
        let clock = clock
        stateTask = Task { @MainActor [weak self, clock] in
            do {
                // Bounded, cancellable coalescing delay for bursty WebKit state KVO.
                try await clock.sleep(for: 0.016)
                guard !Task.isCancelled else { return }
                await self?.emitStateIfChanged()
            } catch {}
        }
    }

    private func emitStateImmediately() {
        stateTask?.cancel()
        stateTask = Task { @MainActor [weak self] in
            await self?.emitStateIfChanged()
        }
    }

    private func emitStateIfChanged() async {
        guard !isStopped else { return }
        let state = wireEncoder.state(panel: panel, editableFocused: editableFocused)
        guard state != lastState, let payload = wireEncoder.object(state) else { return }
        if await connection.sendEvent(topic: "browser.state", payload: payload) {
            lastState = state
        }
    }
}
