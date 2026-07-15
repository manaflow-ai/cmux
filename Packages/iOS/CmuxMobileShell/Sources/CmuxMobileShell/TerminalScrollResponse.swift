import CMUXMobileCore
import CmuxMobileRPC
import Foundation

struct TerminalPreparedRenderGrid: Equatable, Sendable {
    let frame: MobileTerminalRenderGridFrame
    let bytes: Data

    init(frame: MobileTerminalRenderGridFrame, bytes: Data? = nil) {
        self.frame = frame
        self.bytes = bytes ?? frame.vtPatchBytes()
    }
}

struct TerminalScrollResponse: Sendable {
    let accepted: Bool
    let interactionEpoch: UInt64
    let clientRevision: UInt64
    let renderRevision: UInt64?
    let renderGrid: MobileTerminalRenderGridFrame?
    let preparedRenderGrid: TerminalPreparedRenderGrid?

    init(
        accepted: Bool,
        interactionEpoch: UInt64,
        clientRevision: UInt64,
        renderRevision: UInt64?,
        renderGrid: MobileTerminalRenderGridFrame?,
        preparedRenderGridBytes: Data? = nil
    ) {
        self.accepted = accepted
        self.interactionEpoch = interactionEpoch
        self.clientRevision = clientRevision
        self.renderRevision = renderRevision
        self.renderGrid = renderGrid
        self.preparedRenderGrid = renderGrid.map {
            TerminalPreparedRenderGrid(frame: $0, bytes: preparedRenderGridBytes)
        }
    }
}

struct TerminalPreparedReplayResponse: Sendable {
    let bytes: Data?
    let snapshotBytes: Data?
    let renderGrid: TerminalPreparedRenderGrid?
    let sequence: UInt64?
    let columns: Int?
    let rows: Int?
}

/// Serializes render-grid decoding and VT synthesis away from the UI actor.
actor TerminalRenderGridProcessor {
    func processScrollResponse(
        data: Data,
        fallbackInteractionEpoch: UInt64,
        fallbackClientRevision: UInt64
    ) throws -> TerminalScrollResponse {
        let payload = try MobileTerminalScrollResponse.decode(data)
        let frame = payload.renderGrid
        return TerminalScrollResponse(
            accepted: payload.accepted ?? true,
            interactionEpoch: payload.interactionEpoch ?? fallbackInteractionEpoch,
            clientRevision: payload.clientScrollRevision ?? fallbackClientRevision,
            renderRevision: payload.renderRevision ?? frame?.renderRevision,
            renderGrid: frame,
            preparedRenderGridBytes: frame?.vtPatchBytes()
        )
    }

    func processReplayResponse(
        data: Data,
        expectedSurfaceID: String
    ) -> TerminalPreparedReplayResponse {
        guard let payload = try? MobileTerminalReplayResponse.decode(data) else {
            return TerminalPreparedReplayResponse(
                bytes: nil,
                snapshotBytes: nil,
                renderGrid: nil,
                sequence: nil,
                columns: nil,
                rows: nil
            )
        }
        let frame = payload.renderGrid?.surfaceID == expectedSurfaceID
            ? payload.renderGrid
            : nil
        return TerminalPreparedReplayResponse(
            bytes: payload.dataBase64.flatMap { Data(base64Encoded: $0) },
            snapshotBytes: payload.snapshotBase64.flatMap { Data(base64Encoded: $0) },
            renderGrid: frame.map { TerminalPreparedRenderGrid(frame: $0) },
            sequence: payload.sequence,
            columns: payload.columns,
            rows: payload.rows
        )
    }

    func processRenderGridEvent(data: Data) -> TerminalPreparedRenderGrid? {
        let wrappedFrame = (try? MobileTerminalRenderGridEvent.decode(data))?.frame
        let frame = wrappedFrame ?? (try? MobileTerminalRenderGridFrame.decode(data))
        return frame.map { TerminalPreparedRenderGrid(frame: $0) }
    }
}
