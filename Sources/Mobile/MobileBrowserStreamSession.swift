import CMUXMobileCore
import Foundation

@MainActor
final class MobileBrowserStreamSession {
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
                scheduleStateEmission()
            }
            pacing.noteDirty(at: clock.now)
            requestDrive()
        case .stateChanged:
            scheduleStateEmission()
        case .webViewReplaced:
            pacing.noteDirty(at: clock.now)
            emitStateImmediately()
            requestDrive()
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
            case .flowControlled, .idle:
                return
            }
        }
    }

    private func captureAndEmit(
        format: MobileBrowserFrameFormat,
        dirtyGeneration: UInt64
    ) async -> Bool {
        do {
            let pageSize = panel.webView.bounds.size
            let image = try await BrowserScreenshotWebViewSnapshotter.captureVisibleViewport(
                from: panel.webView,
                afterScreenUpdates: true
            )
            guard !isStopped, !Task.isCancelled else { return false }
            let encoded = try frameEncoder.encode(image, format: format)
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
            }
            return delivered
        } catch is CancellationError {
            return false
        } catch {
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
