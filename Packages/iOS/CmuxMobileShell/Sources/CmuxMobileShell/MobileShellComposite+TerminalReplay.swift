import CMUXMobileCore
import CmuxMobileDiagnostics
import CmuxMobileRPC
import CmuxMobileShellModel
import Foundation
import OSLog

private let mobileShellReplayLog = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "dev.cmux.ios",
    category: "mobile-shell"
)

extension MobileShellComposite {
    func executeTerminalReplay(
        surfaceID: String,
        client: MobileCoreRPCClient,
        workspaceID: MobileWorkspacePreview.ID
    ) async -> Bool {
        do {
            let request = try MobileCoreRPCClient.requestData(
                method: "mobile.terminal.replay",
                params: [
                    "workspace_id": workspaceID.rawValue,
                    "surface_id": surfaceID,
                ]
            )
            let data = try await client.sendRequest(request)
            guard remoteClient === client else { return false }
            let payload = try? MobileTerminalReplayResponse.decode(data)
            let bytes = payload?.dataBase64.flatMap { Data(base64Encoded: $0) }
            let snapshotBytes = payload?.snapshotBase64.flatMap { Data(base64Encoded: $0) }
            let decodedRenderGrid = payload?.renderGrid
            let renderGrid = decodedRenderGrid?.surfaceID == surfaceID ? decodedRenderGrid : nil
            let replaySeq = renderGrid?.stateSeq ?? payload?.sequence
            #if DEBUG
            let seq = replaySeq ?? 0
            let cols = payload?.columns ?? -1
            let rows = payload?.rows ?? -1
            mobileShellReplayLog.info("CMUX_REPLAY response surface=\(surfaceID, privacy: .public) byteCount=\(bytes?.count ?? -1, privacy: .public) snapshotBytes=\(snapshotBytes?.count ?? -1, privacy: .public) renderGrid=\(renderGrid != nil, privacy: .public) seq=\(seq, privacy: .public) macGrid=\(cols, privacy: .public)x\(rows, privacy: .public) hasSink=\(self.hasTerminalOutputSink(surfaceID: surfaceID), privacy: .public)")
            #endif
            if let replaySeq,
               terminalOutputAcceptedEndSeq(surfaceID: surfaceID) > replaySeq {
                let acceptedSeq = terminalOutputAcceptedEndSeq(surfaceID: surfaceID)
                MobileDebugLog.anchormux("CMUX_REPLAY stale surface=\(surfaceID) accepted=\(acceptedSeq) replay=\(replaySeq)")
                return false
            }
            let deliverBytes: Data?
            if let renderGrid {
                deliverBytes = nil
                MobileDebugLog.anchormux("CMUX_REPLAY render_grid surface=\(surfaceID) spans=\(renderGrid.rowSpans.count) seq=\(renderGrid.stateSeq)")
            } else if let snapshotBytes, !snapshotBytes.isEmpty {
                deliverBytes = Self.terminalSnapshotReplacementBytes(snapshotBytes)
                MobileDebugLog.anchormux("CMUX_REPLAY snapshot surface=\(surfaceID) bytes=\(snapshotBytes.count) seq=\(replaySeq ?? 0)")
            } else {
                deliverBytes = bytes
                MobileDebugLog.anchormux("CMUX_REPLAY raw_tail surface=\(surfaceID) bytes=\(bytes?.count ?? -1) seq=\(replaySeq ?? 0)")
            }
            if let renderGrid {
                guard hasTerminalOutputSink(surfaceID: surfaceID) else { return false }
                deliverTerminalRenderGrid(renderGrid, surfaceID: surfaceID)
                return true
            }
            guard let deliverBytes, !deliverBytes.isEmpty,
                  hasTerminalOutputSink(surfaceID: surfaceID) else {
                return false
            }
            deliverTerminalBytes(deliverBytes, surfaceID: surfaceID, endSeq: replaySeq)
            return true
        } catch {
            mobileShellReplayLog.error("CMUX_REPLAY failed surface=\(surfaceID, privacy: .public) error=\(String(describing: error), privacy: .public)")
            guard remoteClient === client else { return false }
            _ = disconnectForAuthorizationFailureIfNeeded(error)
            return false
        }
    }
}
