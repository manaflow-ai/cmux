import CmuxIrohTransport
import CmuxSimulator
import CmuxSimulatorStreamKit
import CmuxSimulatorUI
import Foundation
import OSLog
import Observation

private let simStreamV2Log = Logger(subsystem: "dev.cmux", category: "mobile-simstream-v2")

/// Bridges the worker's shared-memory frame reader to the pump's capture seam.
private struct SimStreamReaderSource: SimStreamFrameSource {
    let reader: SimulatorVideoFrameReader

    func copyLatestFrame(after sequence: UInt64?) async -> SimStreamSourceFrame? {
        guard let frame = await reader.copyLatestFrame(after: sequence) else { return nil }
        return SimStreamSourceFrame(
            pixels: frame.pixels,
            width: frame.width,
            height: frame.height,
            bytesPerRow: frame.bytesPerRow,
            sequence: frame.sequence
        )
    }
}

/// Bridges the pump's message sink to the lane's QUIC send half.
private struct SimStreamLaneSink: SimStreamMessageSending {
    let sendStream: any CmxIrohSendStream

    func send(_ data: Data) async throws {
        try await sendStream.send(data)
    }
}

/// Deferred fatal-callback target so the pump (a `let`) can be constructed
/// before the session is fully initialized.
private final class SimStreamFatalRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable (String) -> Void)?

    func install(_ handler: @escaping @Sendable (String) -> Void) {
        lock.lock()
        self.handler = handler
        lock.unlock()
    }

    func fire(_ reason: String) {
        lock.lock()
        let handler = handler
        lock.unlock()
        handler?(reason)
    }
}

/// One simulator-stream v2 lane: the entire viewer relationship for one
/// panel over one QUIC stream. Owns nothing across connections; a transport
/// drop destroys it and the viewer's next `start` builds a fresh one.
@MainActor
final class MobileSimulatorStreamV2Session {
    enum EndReason: String {
        case clientStopped = "client_stopped"
        case laneClosed = "lane_closed"
        case laneFailed = "lane_failed"
        case protocolViolation = "protocol_violation"
        case panelClosed = "panel_closed"
        case featureDisabled = "feature_disabled"
        case panelMissing = "panel_missing"
        case superseded
        case pumpFailed = "pump_failed"
        case connectionClosed = "connection_closed"
    }

    let id = UUID()
    let panelID: UUID

    private let stream: CmxIrohBidirectionalStream
    private unowned let coordinator: MobileSimulatorStreamV2Coordinator
    private let pump: SimStreamHostPump
    private let fatalRelay: SimStreamFatalRelay
    private let clock: any Clock<Duration>

    private var panel: SimulatorPanel?
    private var readerAttachment = MobileSimulatorReaderAttachment<SimulatorVideoFrameReader>()
    private var inputSequenceGuard = SimStreamInputSequenceGuard()
    private var watchdogTask: Task<Void, Never>?
    private var lastReportedStatus: SimStreamHostStatus?
    private var isEnded = false
    private var started = false

    init(
        panelID: UUID,
        stream: CmxIrohBidirectionalStream,
        coordinator: MobileSimulatorStreamV2Coordinator,
        clock: any Clock<Duration> = ContinuousClock()
    ) {
        self.panelID = panelID
        self.stream = stream
        self.coordinator = coordinator
        self.clock = clock
        let relay = SimStreamFatalRelay()
        self.fatalRelay = relay
        self.pump = SimStreamHostPump(
            sink: SimStreamLaneSink(sendStream: stream.sendStream),
            now: { Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000 },
            onFatal: { reason in relay.fire(reason) }
        )
    }

    /// Runs the lane until it ends. Called from (and structured under) the
    /// lane router's task, so a closing connection cancels straight through.
    nonisolated func run() async {
        await installFatalRelay()
        await withTaskCancellationHandler {
            await readLoop()
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.end(reason: .connectionClosed)
            }
        }
    }

    private func installFatalRelay() {
        fatalRelay.install { [weak self] reason in
            Task { @MainActor in
                guard let self, !self.isEnded else { return }
                simStreamV2Log.error("simstream v2 pump fatal: \(reason, privacy: .public)")
                self.end(reason: .pumpFailed)
            }
        }
    }

    // MARK: - Lane read loop

    private nonisolated func readLoop() async {
        var accumulator = SimStreamFrameAccumulator()
        do {
            while let data = try await stream.receiveStream.receive(
                maximumByteCount: 256 * 1024)
            {
                guard !data.isEmpty else { continue }
                accumulator.append(data)
                while let body = try accumulator.nextMessageBody() {
                    let message = try SimStreamWireCodec.decode(body)
                    guard await route(message) else { return }
                }
            }
            await end(reason: .laneClosed)
        } catch is CancellationError {
            await end(reason: .connectionClosed)
        } catch {
            await end(reason: .laneFailed)
        }
    }

    /// Returns false when the loop must stop.
    private func route(_ message: SimStreamMessage) async -> Bool {
        guard !isEnded else { return false }
        switch message {
        case .start(let request):
            await handleStart(request)
            return !isEnded
        case .ack(let ack):
            await pump.noteAck(ack)
            return true
        case .input(let batch):
            handleInput(batch)
            return true
        case .keyframeRequest:
            await pump.requestKeyframe()
            return true
        case .stop:
            end(reason: .clientStopped)
            return false
        case .config, .frame, .state:
            // Host-to-viewer messages arriving from the viewer are a protocol
            // violation; fail closed rather than guessing.
            end(reason: .protocolViolation)
            return false
        }
    }

    // MARK: - Start

    private func handleStart(_ request: SimStreamStartRequest) async {
        guard CmuxFeatureFlags.shared.isSimulatorEnabled else {
            await pump.sendState(
                SimStreamStateUpdate(status: .failed, detail: "simulator_disabled"))
            end(reason: .featureDisabled)
            return
        }
        guard let resolved = Self.resolvePanel(id: panelID) else {
            await pump.sendState(
                SimStreamStateUpdate(status: .closed, detail: "panel_not_found"))
            end(reason: .panelMissing)
            return
        }
        panel = resolved
        if !started {
            started = true
            coordinator.claim(panelID: panelID, session: self)
            resolved.setMobileFrameDemand(true, consumerID: id)
            observeCoordinator()
            startWatchdog()
        }
        await pump.beginStream(request: request, geometry: currentGeometry())
        reportStatusIfChanged()
        refreshReader()
    }

    static func resolvePanel(id: UUID) -> SimulatorPanel? {
        guard let located = AppDelegate.shared?.locateSurface(surfaceId: id),
            let workspace = located.tabManager.tabs.first(where: {
                $0.id == located.workspaceId
            })
        else { return nil }
        return TerminalController.shared.mobileSimulatorPanels(in: workspace)
            .first(where: { $0.id == id })
    }

    // MARK: - Frames

    private func refreshReader() {
        guard started, !isEnded, let panel else { return }
        let paneCoordinator = panel.coordinator
        let readiness = MobileSimulatorReaderReadiness(
            transportName: paneCoordinator.frameTransport?.sharedMemoryName,
            displayScale: paneCoordinator.display?.scale
        )
        let refresh = readerAttachment.refresh(for: readiness) {
            paneCoordinator.makeVideoFrameReader()
        }
        refresh.detachedReader?.setFramePublicationHandler(nil)
        if let reader = refresh.attachedReader {
            let pump = pump
            reader.setFramePublicationHandler {
                pump.signalFramePublished()
            }
            let geometry = currentGeometry()
            Task {
                await pump.setSource(SimStreamReaderSource(reader: reader), geometry: geometry)
            }
        } else if refresh.isMissing {
            let pump = pump
            Task { await pump.setSource(nil, geometry: nil) }
        }
    }

    private func currentGeometry() -> SimStreamHostPump.Geometry {
        let display = panel?.coordinator.display
        return SimStreamHostPump.Geometry(
            displayScale: Float(display?.scale ?? 2.0),
            orientation: Self.wireOrientation(display?.orientation ?? .portrait)
        )
    }

    // MARK: - Coordinator observation

    private func observeCoordinator() {
        guard !isEnded, let paneCoordinator = panel?.coordinator else { return }
        withObservationTracking {
            _ = paneCoordinator.status
            _ = paneCoordinator.frameTransport?.sharedMemoryName
            _ = paneCoordinator.display
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, !self.isEnded else { return }
                self.coordinatorDidChange()
                self.observeCoordinator()
            }
        }
    }

    private func coordinatorDidChange() {
        refreshReader()
        reportStatusIfChanged()
    }

    private func reportStatusIfChanged() {
        guard let paneCoordinator = panel?.coordinator else { return }
        let status = Self.wireStatus(paneCoordinator.status)
        guard status != lastReportedStatus else { return }
        lastReportedStatus = status
        let pump = pump
        Task { await pump.sendState(SimStreamStateUpdate(status: status)) }
    }

    // MARK: - Input

    private func handleInput(_ batch: SimStreamInputBatch) {
        guard inputSequenceGuard.shouldApply(batch), !isEnded,
            let paneCoordinator = panel?.coordinator
        else { return }
        // Viewer coordinates are normalized to the displayed (rotated) frame;
        // the worker HID digitizer expects raw portrait space, the same
        // mapping the Mac pane and CLI gesture paths apply.
        let geometry = paneCoordinator.display.map(SimulatorOrientationGeometry.init(display:))
        for event in batch.events {
            switch event {
            case .touch(let phase, let pointerID, let x, let y, _):
                // Single-pointer injection matches the worker HID surface the
                // Mac pane uses; additional pointers are dropped, not queued.
                guard pointerID == 0 else { continue }
                let displayed = SimulatorPoint(x: Double(x), y: Double(y))
                let point = geometry?.rawPoint(for: displayed) ?? displayed
                switch phase {
                case .began:
                    paneCoordinator.beginTouch(at: point)
                case .moved:
                    paneCoordinator.moveTouch(to: point)
                case .ended, .cancelled:
                    paneCoordinator.endTouch(at: point)
                }
            case .text(let text):
                _ = paneCoordinator.typeText(text)
            case .key(let usage, let isDown):
                paneCoordinator.sendKey(usage: UInt32(usage), isDown: isDown)
            case .button(let button):
                paneCoordinator.press(Self.hardwareButton(button))
            }
        }
    }

    // MARK: - Watchdog

    private func startWatchdog() {
        let clock = clock
        watchdogTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await clock.sleep(for: .seconds(3))
                guard let self else { return }
                let ended = await self.watchdogTick()
                if ended { return }
            }
        }
    }

    /// Returns true when the session ended.
    private func watchdogTick() async -> Bool {
        guard started, !isEnded else { return true }
        guard Self.resolvePanel(id: panelID) != nil else {
            await pump.sendState(SimStreamStateUpdate(status: .closed, detail: "panel_closed"))
            end(reason: .panelClosed)
            return true
        }
        if panel?.coordinator.status == .streaming {
            if readerAttachment.reader == nil {
                refreshReader()
            } else if await pump.isStalled(olderThan: 5) {
                // Booted, attached, credit available, yet nothing flowed:
                // resync the capture attachment and force a keyframe.
                simStreamV2Log.info("simstream v2 watchdog resync panel \(self.panelID)")
                readerAttachment.detach()?.setFramePublicationHandler(nil)
                refreshReader()
                await pump.requestKeyframe()
            }
        }
        return isEnded
    }

    // MARK: - Teardown

    func end(reason: EndReason) {
        guard !isEnded else { return }
        isEnded = true
        watchdogTask?.cancel()
        watchdogTask = nil
        readerAttachment.detach()?.setFramePublicationHandler(nil)
        panel?.setMobileFrameDemand(false, consumerID: id)
        panel = nil
        let pump = pump
        let stream = stream
        let sendClosedState = reason == .superseded
        Task {
            if sendClosedState {
                await pump.sendState(
                    SimStreamStateUpdate(status: .closed, detail: "superseded"))
            }
            await pump.shutdown()
            try? await stream.sendStream.finish()
            await stream.receiveStream.stop(errorCode: 0)
        }
        coordinator.sessionEnded(self)
        simStreamV2Log.info(
            "simstream v2 session ended panel \(self.panelID) reason \(reason.rawValue, privacy: .public)"
        )
    }

    // MARK: - Mappings

    private static func wireOrientation(
        _ orientation: SimulatorOrientation
    ) -> SimStreamOrientation {
        switch orientation {
        case .portrait: .portrait
        case .portraitUpsideDown: .portraitUpsideDown
        case .landscapeLeft: .landscapeLeft
        case .landscapeRight: .landscapeRight
        }
    }

    private static func wireStatus(_ status: SimulatorSessionStatus) -> SimStreamHostStatus {
        switch status {
        case .idle, .connecting: .preparing
        case .streaming: .streaming
        case .deviceUnavailable: .deviceUnavailable
        case .workerCrashed: .workerCrashed
        case .failed: .failed
        }
    }

    private static func hardwareButton(
        _ button: SimStreamHardwareButton
    ) -> SimulatorHardwareButton {
        switch button {
        case .home: .home
        case .lock: .lock
        case .siri: .siri
        case .sideButton: .sideButton
        case .appSwitcher: .appSwitcher
        case .volumeUp: .volumeUp
        case .volumeDown: .volumeDown
        case .power: .power
        case .swipeHome: .swipeHome
        }
    }
}
