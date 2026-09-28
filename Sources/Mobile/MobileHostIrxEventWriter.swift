import CmuxIrxTransport
import Foundation
import os

/// Server-events lane writer over irx: opened lazily at priority 50, reset on
/// stall so the host service can renegotiate, mirroring the legacy contract.
///
/// When the phone negotiated surface lanes, each terminal's render-grid frames
/// go on their own uni stream (``IrxSurfaceEventLanes``) instead of this
/// shared lane, so a burst for one terminal cannot delay another's echo.
///
/// Once the phone lists an ``IrxLaneEncoding`` on subscribe, every lane opened
/// afterwards compresses its whole byte stream; lanes already open keep the
/// identity encoding their descriptor declared.
actor MobileHostIrxEventWriter: MobileHostIndependentEventWriting {
    private let connection: IrxConnection
    private let journal: IrxJournal
    private let surfaceLanes: IrxSurfaceEventLanes
    private let laneEncoding: OSAllocatedUnfairLock<IrxLaneEncoding?>
    private var writer: (any IrxEventLaneWriting)?

    nonisolated let maximumSurfaceEventLaneCount: Int

    init(
        connection: IrxConnection,
        journal: IrxJournal,
        surfaceLaneConfiguration: IrxSurfaceEventLanes.Configuration = .init()
    ) {
        self.connection = connection
        self.journal = journal
        let laneEncoding = OSAllocatedUnfairLock<IrxLaneEncoding?>(initialState: nil)
        self.laneEncoding = laneEncoding
        maximumSurfaceEventLaneCount = surfaceLaneConfiguration.maximumLaneCount
        surfaceLanes = IrxSurfaceEventLanes(
            configuration: surfaceLaneConfiguration,
            journal: journal,
            open: { descriptor in
                try await Self.openLane(
                    descriptor,
                    encoding: laneEncoding.withLock { $0 },
                    on: connection
                )
            }
        )
    }

    nonisolated func setLaneEncoding(_ encoding: IrxLaneEncoding?) {
        laneEncoding.withLock { $0 = encoding }
    }

    private static func openLane(
        _ descriptor: IrxLaneDescriptor,
        encoding: IrxLaneEncoding?,
        on connection: IrxConnection
    ) async throws -> any IrxEventLaneWriting {
        var descriptor = descriptor
        descriptor.encoding = encoding?.rawValue
        let opened = try await connection.openUniLane(descriptor)
        guard let encoding else { return opened }
        do {
            return try IrxEncodingLaneWriter(opened, encoding: encoding)
        } catch {
            await opened.reset(errorCode: IrxSurfaceEventLanes.writeFailedResetCode)
            throw error
        }
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

    private func openedWriter() async throws -> any IrxEventLaneWriting {
        if let writer { return writer }
        let opened = try await Self.openLane(
            IrxLaneDescriptor(lane: .events),
            encoding: laneEncoding.withLock { $0 },
            on: connection
        )
        try? await opened.setPriority(50)
        writer = opened
        journal.record("host-events", "writer-opened")
        return opened
    }
}
