import CmuxIrohTransport
import Foundation
import OSLog

private let simStreamV2CoordinatorLog = Logger(
    subsystem: "dev.cmux", category: "mobile-simstream-v2")

/// Router registration glue: forwards admitted simulator-stream lanes to the
/// process-wide v2 coordinator.
struct MobileHostIrohSimulatorStreamLaneHandler: MobileHostIrohSimulatorStreamLaneHandling {
    func handleSimulatorStreamLane(
        resourceID: CmxIrohResourceID,
        stream: CmxIrohBidirectionalStream,
        peer: CmxIrohAdmittedPeer
    ) async -> Bool {
        await MobileSimulatorStreamV2Coordinator.shared.handleLane(
            resourceID: resourceID,
            stream: stream,
            peer: peer
        )
    }
}

/// Session registry for simulator-stream v2 lanes with last-writer-wins
/// panel ownership: a new `start` for a panel supersedes any existing
/// session, so a dead connection can never hold a panel hostage and a
/// reconnecting phone self-heals with its own next attach. Every lane
/// belongs to an admitted same-account peer, so takeover is always the
/// account owner displacing their own older viewer.
@MainActor
final class MobileSimulatorStreamV2Coordinator {
    static let shared = MobileSimulatorStreamV2Coordinator()

    private var sessionsByPanelID: [UUID: MobileSimulatorStreamV2Session] = [:]

    /// Lane entry point, called (and structured) under the lane router's
    /// task so connection teardown cancels straight into the session.
    nonisolated func handleLane(
        resourceID: CmxIrohResourceID,
        stream: CmxIrohBidirectionalStream,
        peer: CmxIrohAdmittedPeer
    ) async -> Bool {
        guard let panelID = Self.panelID(from: resourceID) else { return false }
        // Below terminal PTY bytes (0), above bulk artifacts (-10): video
        // never delays typing and always beats file transfers.
        try? await stream.sendStream.setPriority(-5)
        let session = await makeSession(panelID: panelID, stream: stream)
        await session.run()
        return true
    }

    private func makeSession(
        panelID: UUID, stream: CmxIrohBidirectionalStream
    ) -> MobileSimulatorStreamV2Session {
        MobileSimulatorStreamV2Session(
            panelID: panelID, stream: stream, coordinator: self)
    }

    /// Grants panel ownership to `session`, ending any previous owner.
    func claim(panelID: UUID, session: MobileSimulatorStreamV2Session) {
        if let previous = sessionsByPanelID[panelID], previous !== session {
            simStreamV2CoordinatorLog.info(
                "simstream v2 panel \(panelID) superseded by newer session")
            previous.end(reason: .superseded)
        }
        sessionsByPanelID[panelID] = session
    }

    func sessionEnded(_ session: MobileSimulatorStreamV2Session) {
        guard sessionsByPanelID[session.panelID] === session else { return }
        sessionsByPanelID[session.panelID] = nil
    }

    nonisolated static func panelID(from resourceID: CmxIrohResourceID) -> UUID? {
        let value = resourceID.value
        let raw =
            value.hasPrefix("simstream:")
            ? String(value.dropFirst("simstream:".count))
            : value
        return UUID(uuidString: raw)
    }
}
