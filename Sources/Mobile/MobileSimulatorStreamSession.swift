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

    init(
        connectionID: UUID,
        panel: SimulatorPanel,
        connection: MobileHostConnection,
        cachedFrame: MobileSimulatorFrameEvent?,
        descriptorProvider: @escaping @MainActor (UUID) -> MobileSimulatorPanelDescriptor?,
        onFrame: @escaping @MainActor (UUID, MobileSimulatorFrameEvent) -> Void,
        onEnded: @escaping @MainActor (UUID) -> Void
    ) {
        self.connectionID = connectionID
        self.panelID = panel.id
        self.panel = panel
        self.connection = connection
        self.cachedFrame = cachedFrame
        self.descriptorProvider = descriptorProvider
        self.onFrame = onFrame
        self.onEnded = onEnded
    }

    func start() {
        guard !isStopped else { return }
        panel.setVisibleInUI(true, hostID: id)
        observeCoordinator()
        emitState()
        emitCachedFrameIfNeeded()
        refreshReader()
        requestFrameSend()
    }

    func stop(sendClosed: Bool) async {
        guard !isStopped else { return }
        isStopped = true
        frameTask?.cancel()
        frameTask = nil
        stateTask?.cancel()
        stateTask = nil
        reader?.setFramePublicationHandler(nil)
        reader = nil
        panel.setVisibleInUI(false, hostID: id)
        if sendClosed,
           let payload = wireEncoder.object(MobileSimulatorClosedEvent(panelID: panelID.uuidString)) {
            _ = await connection.sendEvent(topic: "simulator.closed", payload: payload)
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
        reader?.setFramePublicationHandler(nil)
        reader = nil
        observedFrameTransportName = transportName
        guard transportName != nil else { return }
        guard let reader = panel.coordinator.makeMobileFrameReader() else { return }
        self.reader = reader
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
            guard let payload = wireEncoder.object(event) else { continue }
            let delivered = await connection.sendEvent(topic: "simulator.frame", payload: payload)
            guard delivered else {
                // A refused frame means the connection is closed or its
                // bounded event queue overflowed into a close; no later send
                // will succeed. End the session so the coordinator releases
                // the panel's control lock now, instead of another phone
                // seeing `.locked` until the registry's connection-closed
                // sweep runs.
                await endAfterDeliveryFailure()
                return
            }
            lastSentSequence = event.sequence
            cachedFrame = event
            onFrame(panelID, event)
        }
    }

    private func endAfterDeliveryFailure() async {
        guard !isStopped else { return }
        await stop(sendClosed: false)
        onEnded(id)
    }

    private func nextFrameEvent() async -> MobileSimulatorFrameEvent? {
        guard let reader else { return nil }
        guard reader.hasPublishedFrame(after: lastSentSequence) else { return nil }
        guard let frame = await reader.copyLatestFrame(after: lastSentSequence) else { return nil }
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
            _ = await self.connection.sendEvent(topic: "simulator.frame", payload: payload)
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
