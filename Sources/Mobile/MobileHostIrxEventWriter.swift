import CmuxIrxTransport
import Foundation

/// Server-events lane writer over irx: opened lazily at priority 50, reset on
/// stall so the host service can renegotiate, mirroring the legacy contract.
///
/// When the phone negotiated surface lanes, the focused terminal's render-grid
/// frames go on their own uni stream (``IrxSurfaceEventLanes``) instead of this
/// shared lane, so background output cannot delay its echo.
actor MobileHostIrxEventWriter: MobileHostIndependentEventWriting {
    private let connection: IrxConnection
    private let journal: IrxJournal
    private let surfaceLanes: IrxSurfaceEventLanes
    private var writer: IrxStreamWriter?
    private var interactiveSurfaceHandler: (@Sendable (String) async -> Void)?
    private var lastReportedInteractiveSurface: String?

    /// Only the terminal the user is looking at gets its own stream. The
    /// phone shows one terminal, and a lane per background terminal only let
    /// their output compete with the echo and churn the phone's stream credit.
    static let focusedSurfaceLaneCount = 1

    nonisolated let maximumSurfaceEventLaneCount = MobileHostIrxEventWriter.focusedSurfaceLaneCount

    init(
        connection: IrxConnection,
        journal: IrxJournal,
        surfaceLaneConfiguration: IrxSurfaceEventLanes.Configuration = .init()
    ) {
        self.connection = connection
        self.journal = journal
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

    func releaseSurfaceLanes(_ generationsBySurfaceID: [String: UInt64]) async {
        for (surfaceID, generation) in generationsBySurfaceID {
            await surfaceLanes.release(surfaceID: surfaceID, belowGeneration: generation)
        }
    }

    func setInteractiveSurfaceHandler(_ handler: (@Sendable (String) async -> Void)?) async {
        interactiveSurfaceHandler = handler
        if let handler, let lastReportedInteractiveSurface {
            await handler(lastReportedInteractiveSurface)
        }
    }

    /// Input arrived on the surface's input lane, which bypasses the
    /// connection actor. The connection decides which surface holds a lane;
    /// until it registers, only the stream priority follows the input.
    func reportInteractiveSurface(_ surfaceID: String) async {
        lastReportedInteractiveSurface = surfaceID
        if let interactiveSurfaceHandler {
            await interactiveSurfaceHandler(surfaceID)
        } else {
            await surfaceLanes.noteFocused(surfaceID: surfaceID)
        }
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
