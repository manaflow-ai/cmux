import CmuxIrxTransport
import Foundation

/// Server-events lane writer over irx: opened lazily at priority 50, reset on
/// stall so the host service can renegotiate, mirroring the legacy contract.
///
/// When the phone negotiated surface lanes, each terminal's render-grid frames
/// go on their own uni stream (``IrxSurfaceEventLanes``) instead of this
/// shared lane, so a burst for one terminal cannot delay another's echo.
actor MobileHostIrxEventWriter: MobileHostIndependentEventWriting {
    private let connection: IrxConnection
    private let journal: IrxJournal
    private let surfaceLanes: IrxSurfaceEventLanes
    private var writer: IrxStreamWriter?

    nonisolated let maximumSurfaceEventLaneCount: Int

    init(
        connection: IrxConnection,
        journal: IrxJournal,
        surfaceLaneConfiguration: IrxSurfaceEventLanes.Configuration = .init()
    ) {
        self.connection = connection
        self.journal = journal
        maximumSurfaceEventLaneCount = surfaceLaneConfiguration.maximumLaneCount
        surfaceLanes = IrxSurfaceEventLanes(
            configuration: surfaceLaneConfiguration,
            journal: journal,
            open: { descriptor in
                try await connection.openUniLane(descriptor)
            }
        )
    }

    func probe(_ framedData: Data) async -> Bool {
        do {
            try await send(framedData)
            return true
        } catch {
            return false
        }
    }

    func send(_ framedData: Data) async throws {
        let writer = try await openedWriter()
        try await writer.write(framedData)
    }

    func reset() async {
        if let writer {
            await writer.finish()
        }
        writer = nil
        journal.record("host-events", "writer-reset")
    }

    func close() async {
        await surfaceLanes.closeAll()
        if let writer {
            await writer.finish()
        }
        writer = nil
    }

    func sendSurfaceEvent(_ framedData: Data, surfaceID: String, generation: UInt64) async throws {
        try await surfaceLanes.send(framedData, surfaceID: surfaceID, generation: generation)
    }

    func setSurfaceEventLanesEnabled(_ enabled: Bool) async {
        await surfaceLanes.setEnabled(enabled)
        journal.record("host-events", enabled ? "surface-lanes-enabled" : "surface-lanes-disabled")
    }

    func noteInteractiveSurface(_ surfaceID: String) async {
        await surfaceLanes.noteFocused(surfaceID: surfaceID)
    }

    private func openedWriter() async throws -> IrxStreamWriter {
        if let writer { return writer }
        let opened = try await connection.openUniLane(IrxLaneDescriptor(lane: .events))
        try? await opened.setPriority(50)
        writer = opened
        journal.record("host-events", "writer-opened")
        return opened
    }
}
