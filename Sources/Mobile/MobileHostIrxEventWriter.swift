import CmuxIrxTransport
import Foundation

/// Server-events lane writer over irx: opened lazily at priority 50, reset on
/// stall so the host service can renegotiate, mirroring the legacy contract.
///
/// When the phone negotiated surface lanes, the focused terminal's render-grid
/// frames go on its own uni stream (``IrxSurfaceEventLanes``) instead of this
/// shared lane, so background output cannot delay its echo.
actor MobileHostIrxEventWriter: MobileHostIndependentEventWriting {
    private let connection: IrxConnection
    private let journal: IrxJournal
    private let surfaceLanes: IrxSurfaceEventLanes
    private var writer: IrxStreamWriter?
    private var interactiveSurfaceHandler: (@Sendable (String) async -> Void)?
    /// A lane can report its initial surface before the RPC event subscription
    /// installs the connection-owned handler. This is only a bridge buffer;
    /// the connection remains the owner of focus state and transitions.
    private var pendingInteractiveSurface: String?

    /// Only the terminal the user is looking at gets a dedicated stream.
    static let focusedSurfaceLaneCount = 1

    nonisolated let maximumSurfaceEventLaneCount = MobileHostIrxEventWriter.focusedSurfaceLaneCount

    init(
        connection: IrxConnection,
        journal: IrxJournal,
        surfaceLaneConfiguration: IrxSurfaceEventLanes.Configuration = .init()
    ) {
        self.connection = connection
        self.journal = journal
        var boundedConfiguration = surfaceLaneConfiguration
        // The queue admits one logical focused lane. The native budget also
        // covers streams still retiring after a focus switch, so keep the
        // caller's bounded cleanup allowance instead of collapsing it to one
        // and forcing every quick switch onto the shared lane.
        boundedConfiguration.maximumLaneCount = max(
            Self.focusedSurfaceLaneCount,
            boundedConfiguration.maximumLaneCount
        )
        surfaceLanes = IrxSurfaceEventLanes(
            configuration: boundedConfiguration,
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
        interactiveSurfaceHandler = nil
        pendingInteractiveSurface = nil
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

    func setInteractiveSurfaceHandler(
        _ handler: (@Sendable (String) async -> Void)?
    ) async {
        interactiveSurfaceHandler = handler
        if let handler, let pendingInteractiveSurface {
            self.pendingInteractiveSurface = nil
            await handler(pendingInteractiveSurface)
        }
    }

    /// Reports input-lane focus to the owning connection. Lane assignment is
    /// deliberately not performed here, so one connection owns focus, queue
    /// routing, stream release, and priority updates in order.
    func reportInteractiveSurface(_ surfaceID: String) async {
        if let interactiveSurfaceHandler {
            await interactiveSurfaceHandler(surfaceID)
        } else {
            pendingInteractiveSurface = surfaceID
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
