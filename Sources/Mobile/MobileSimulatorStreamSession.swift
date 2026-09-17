import CMUXMobileCore
import CmuxSimulatorUI
import Foundation
import Observation

@MainActor
final class MobileSimulatorStreamSession {
    let id = UUID()
    let connectionID: UUID
    let panelID: UUID

    private let panel: SimulatorPanel
    private let connection: MobileHostConnection
    private let descriptorProvider: @MainActor (UUID) -> MobileSimulatorPanelDescriptor?
    private let onFrame: @MainActor (UUID, MobileSimulatorFrameEvent) -> Void
    private let onEnded: @MainActor (UUID) -> Void
    private let wireEncoder = MobileSimulatorWireEncoder()

    private var cachedFrame: MobileSimulatorFrameEvent?
    private var reader: SimulatorMobileFrameReader?
    private var observedFrameTransportName: String?
    private var lastSentSequence: UInt64?
    private var isStopped = false
    private var isSendingFrame = false
    private var needsFrameSend = false
    private var frameTask: Task<Void, Never>?
    private var stateTask: Task<Void, Never>?
    private var keepaliveTask: Task<Void, Never>?
    private var subscriptionObserver: NSObjectProtocol?
    private let keepaliveClock: any Clock<Duration>
    private let keepaliveInterval: Duration

    init(
        connectionID: UUID,
        panel: SimulatorPanel,
        connection: MobileHostConnection,
        cachedFrame: MobileSimulatorFrameEvent?,
        descriptorProvider: @escaping @MainActor (UUID) -> MobileSimulatorPanelDescriptor?,
        onFrame: @escaping @MainActor (UUID, MobileSimulatorFrameEvent) -> Void,
        onEnded: @escaping @MainActor (UUID) -> Void,
        keepaliveClock: any Clock<Duration> = ContinuousClock(),
        keepaliveInterval: Duration = .seconds(5)
    ) {
        self.connectionID = connectionID
        self.panelID = panel.id
        self.panel = panel
        self.connection = connection
        self.cachedFrame = cachedFrame
        self.descriptorProvider = descriptorProvider
        self.onFrame = onFrame
        self.onEnded = onEnded
        self.keepaliveClock = keepaliveClock
        self.keepaliveInterval = keepaliveInterval
    }

    func start() {
        guard !isStopped else { return }
        panel.setVisibleInUI(true, hostID: id)
        observeEventSubscriptions()
        observeCoordinator()
        emitState()
        emitCachedFrameIfNeeded()
        refreshReader()
        requestFrameSend()
        startKeepalive()
    }

    func stop(sendClosed: Bool) async {
        guard !isStopped else { return }
        isStopped = true
        frameTask?.cancel()
        frameTask = nil
        stateTask?.cancel()
        stateTask = nil
        keepaliveTask?.cancel()
        keepaliveTask = nil
        if let subscriptionObserver {
            NotificationCenter.default.removeObserver(subscriptionObserver)
            self.subscriptionObserver = nil
        }
        _ = reader?.setFramePublicationHandler(nil)
        reader = nil
        panel.setVisibleInUI(false, hostID: id)
        if sendClosed,
           let payload = wireEncoder.object(MobileSimulatorClosedEvent(panelID: panelID.uuidString)) {
            _ = await connection.sendEvent(topic: "simulator.closed", payload: payload)
        }
    }

    private func observeEventSubscriptions() {
        guard subscriptionObserver == nil else { return }
        subscriptionObserver = NotificationCenter.default.addObserver(
            forName: .mobileHostEventSubscriptionsDidChange,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            let changedTopics = notification.userInfo?["topics"] as? [String]
            Task { @MainActor [weak self, changedTopics] in
                guard let self, !self.isStopped else { return }
                if let changedTopics,
                   !changedTopics.contains("simulator.frame")
                    && !changedTopics.contains("simulator.state") {
                    return
                }
                MobileSimulatorDiagnostics.recordFrame(
                    panelID: self.panelID,
                    state: .subscriptionReasserted,
                    sequence: self.lastSentSequence
                )
                self.emitState()
                self.requestFrameSend()
            }
        }
    }

    /// Re-emits the panel descriptor on a fixed cadence while the session is
    /// active (capability `simulator.keepalive.v1`). This gives clients a
    /// liveness signal that keeps flowing when the Simulator screen is static,
    /// so event silence past their staleness threshold truthfully means the
    /// session or transport is gone. The paired `requestFrameSend()` also
    /// retries the latest frame after a refused send that no new frame
    /// publication would otherwise retrigger.
    private func startKeepalive() {
        guard keepaliveTask == nil, !isStopped else { return }
        keepaliveTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self, !self.isStopped else { return }
                do {
                    try await self.keepaliveClock.sleep(for: self.keepaliveInterval)
                } catch {
                    return
                }
                guard !self.isStopped, !Task.isCancelled else { return }
                self.emitState()
                // Only retry frames when a reader exists; a panel without a
                // frame transport would otherwise log a readerMissing
                // diagnostic on every keepalive tick.
                if self.reader != nil {
                    self.requestFrameSend()
                }
            }
        }
    }

    private func observeCoordinator() {
        guard !isStopped else { return }
        withObservationTracking {
            _ = panel.coordinator.frameTransport?.sharedMemoryName
            _ = panel.coordinator.display?.scale
            _ = panel.coordinator.status
            _ = panel.coordinator.capabilities
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, !self.isStopped else { return }
                self.observeCoordinator()
                self.emitState()
                self.refreshReader()
                self.requestFrameSend()
            }
        }
    }

    private func refreshReader() {
        let transportName = panel.coordinator.frameTransport?.sharedMemoryName
        guard transportName != observedFrameTransportName else { return }
        _ = reader?.setFramePublicationHandler(nil)
        reader = nil
        observedFrameTransportName = transportName
        guard transportName != nil else {
            MobileSimulatorDiagnostics.recordFrame(panelID: panelID, state: .readerMissing)
            return
        }
        guard let reader = panel.coordinator.makeMobileFrameReader() else {
            MobileSimulatorDiagnostics.recordFrame(panelID: panelID, state: .readerMissing)
            return
        }
        self.reader = reader
        MobileSimulatorDiagnostics.recordFrame(panelID: panelID, state: .readerAttached)
        _ = reader.setFramePublicationHandler { [weak self] in
            Task { @MainActor [weak self] in
                self?.requestFrameSend()
            }
        }
    }

    private func requestFrameSend() {
        guard !isStopped else { return }
        needsFrameSend = true
        guard !isSendingFrame else { return }
        isSendingFrame = true
        frameTask = Task { @MainActor [weak self] in
            await self?.sendFrameLoop()
        }
    }

    private func sendFrameLoop() async {
        defer {
            isSendingFrame = false
            frameTask = nil
            if needsFrameSend, !isStopped {
                requestFrameSend()
            }
        }
        while !isStopped, !Task.isCancelled, needsFrameSend {
            needsFrameSend = false
            guard let event = await nextFrameEvent() else { return }
            let payloadBytes = event.dataBase64.utf8.count
            guard let payload = wireEncoder.object(event) else {
                MobileSimulatorDiagnostics.recordFrame(
                    panelID: panelID,
                    state: .encodeFailed,
                    sequence: event.sequence,
                    payloadBytes: payloadBytes
                )
                continue
            }
            let delivered = await connection.sendEvent(topic: "simulator.frame", payload: payload)
            guard delivered else {
                // A refused frame can be a transient event-subscription gap or
                // a bounded-queue shed while the RPC control lane remains
                // healthy. Keep the control session alive; a later frame
                // publication or subscription reassertion will retry the
                // current latest frame because `lastSentSequence` is unchanged.
                MobileSimulatorDiagnostics.recordFrame(
                    panelID: panelID,
                    state: .refused,
                    sequence: event.sequence,
                    payloadBytes: payloadBytes
                )
                return
            }
            MobileSimulatorDiagnostics.recordFrame(
                panelID: panelID,
                state: .sent,
                sequence: event.sequence,
                payloadBytes: payloadBytes
            )
            lastSentSequence = event.sequence
            cachedFrame = event
            onFrame(panelID, event)
        }
    }

    private func nextFrameEvent() async -> MobileSimulatorFrameEvent? {
        guard let reader else {
            MobileSimulatorDiagnostics.recordFrame(panelID: panelID, state: .readerMissing)
            return nil
        }
        guard reader.hasPublishedFrame(after: lastSentSequence) else { return nil }
        guard let frame = await reader.copyLatestFrame(after: lastSentSequence) else { return nil }
        MobileSimulatorDiagnostics.recordFrame(
            panelID: panelID,
            state: .copied,
            sequence: frame.sequence,
            payloadBytes: frame.data.count
        )
        let format: MobileSimulatorFrameFormat
        switch frame.format {
        case .jpeg:
            format = .jpeg
        case .png:
            format = .png
        }
        return MobileSimulatorFrameEvent(
            panelID: panelID.uuidString,
            sequence: frame.sequence,
            format: format,
            pixelWidth: frame.pixelWidth,
            pixelHeight: frame.pixelHeight,
            displayScale: frame.displayScale,
            dataBase64: frame.data.base64EncodedString()
        )
    }

    private func emitCachedFrameIfNeeded() {
        guard let cachedFrame else { return }
        stateTask = Task { @MainActor [weak self] in
            guard let self, !self.isStopped else { return }
            guard let payload = self.wireEncoder.object(cachedFrame) else { return }
            let delivered = await self.connection.sendEvent(topic: "simulator.frame", payload: payload)
            MobileSimulatorDiagnostics.recordFrame(
                panelID: self.panelID,
                state: delivered ? .cachedSent : .refused,
                sequence: cachedFrame.sequence,
                payloadBytes: cachedFrame.dataBase64.utf8.count
            )
        }
    }

    private func emitState() {
        guard !isStopped,
              let descriptor = descriptorProvider(connectionID),
              let payload = wireEncoder.object(descriptor) else { return }
        stateTask?.cancel()
        stateTask = Task { @MainActor [weak self] in
            guard let self, !self.isStopped else { return }
            _ = await self.connection.sendEvent(topic: "simulator.state", payload: payload)
        }
    }
}
