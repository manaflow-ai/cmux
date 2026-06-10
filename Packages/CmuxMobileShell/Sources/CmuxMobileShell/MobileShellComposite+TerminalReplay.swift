internal import CMUXMobileCore
internal import CmuxMobileDiagnostics
public import CmuxMobileRPC
public import Foundation
internal import OSLog

private let mobileShellLog = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "dev.cmux.ios",
    category: "mobile-shell"
)

// MARK: - Terminal replay (cold attach + deeper-scrollback fetch)
extension MobileShellComposite {
    /// Request a single deeper-scrollback replay for local (primary-screen)
    /// scroll: when the phone scrolls to the top of locally-held history, this
    /// re-requests the render-grid with a larger `scrollback_lines` budget so the
    /// full-snapshot reflow grows the local surface's history. One RPC, not
    /// per-frame; shares the in-flight guard with the cold-attach replay so it
    /// can't pile up. The Mac clamps the budget to its own maximum.
    /// - Parameters:
    ///   - surfaceID: The terminal surface identifier.
    ///   - scrollbackLines: How many scrollback rows to request.
    public func requestDeeperScrollback(surfaceID: String, scrollbackLines: Int) {
        requestTerminalReplay(surfaceID: surfaceID, scrollbackLines: max(0, scrollbackLines))
    }

    /// Cold-attach/self-heal replay. Prefer the Mac's bounded render-grid
    /// snapshot, replacing the local iOS terminal state before live bytes
    /// resume. The VT snapshot and raw byte ring remain fallbacks, but neither
    /// is the target architecture: a byte tail is not a complete screen state
    /// for TUIs, and a VT export is still a replay stream rather than state.
    /// `scrollbackLines` (when set) requests a deeper-history snapshot for local
    /// scroll; nil uses the Mac's default attach-time budget.
    func requestTerminalReplay(surfaceID: String, scrollbackLines: Int? = nil) {
        guard let client = remoteClient else {
            #if DEBUG
            mobileShellLog.error("CMUX_REPLAY skip surface=\(surfaceID, privacy: .public) reason=no_remote_client")
            #endif
            return
        }
        guard let workspaceID = workspaceID(forTerminalID: surfaceID) else {
            #if DEBUG
            mobileShellLog.error("CMUX_REPLAY skip surface=\(surfaceID, privacy: .public) reason=workspace_not_found")
            #endif
            return
        }
        guard !terminalReplaySurfaceIDsInFlight.contains(surfaceID) else {
            #if DEBUG
            mobileShellLog.info("CMUX_REPLAY skip surface=\(surfaceID, privacy: .public) reason=in_flight")
            #endif
            return
        }
        terminalReplaySurfaceIDsInFlight.insert(surfaceID)
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.terminalReplaySurfaceIDsInFlight.remove(surfaceID) }
            do {
                var replayParams: [String: Any] = [
                    "workspace_id": workspaceID.rawValue,
                    "surface_id": surfaceID,
                ]
                if let scrollbackLines {
                    replayParams["scrollback_lines"] = scrollbackLines
                }
                let request = try MobileCoreRPCClient.requestData(
                    method: "mobile.terminal.replay",
                    params: replayParams
                )
                let data = try await client.sendRequest(request)
                guard self.remoteClient === client else { return }
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
                mobileShellLog.info("CMUX_REPLAY response surface=\(surfaceID, privacy: .public) byteCount=\(bytes?.count ?? -1, privacy: .public) snapshotBytes=\(snapshotBytes?.count ?? -1, privacy: .public) renderGrid=\(renderGrid != nil, privacy: .public) seq=\(seq, privacy: .public) macGrid=\(cols, privacy: .public)x\(rows, privacy: .public) hasSink=\(self.hasTerminalOutputSink(surfaceID: surfaceID), privacy: .public)")
                #endif
                if let replaySeq,
                   let deliveredSeq = self.deliveredTerminalByteEndSeqBySurfaceID[surfaceID],
                   deliveredSeq > replaySeq {
                    MobileDebugLog.anchormux("CMUX_REPLAY stale surface=\(surfaceID) delivered=\(deliveredSeq) replay=\(replaySeq)")
                    return
                }
                let deliverBytes: Data?
                if let renderGrid {
                    deliverBytes = renderGrid.vtPatchBytes()
                    MobileDebugLog.anchormux("CMUX_REPLAY render_grid surface=\(surfaceID) spans=\(renderGrid.rowSpans.count) seq=\(renderGrid.stateSeq)")
                } else if let snapshotBytes, !snapshotBytes.isEmpty {
                    deliverBytes = Self.terminalSnapshotReplacementBytes(snapshotBytes)
                    MobileDebugLog.anchormux("CMUX_REPLAY snapshot surface=\(surfaceID) bytes=\(snapshotBytes.count) seq=\(replaySeq ?? 0)")
                } else {
                    deliverBytes = bytes
                    MobileDebugLog.anchormux("CMUX_REPLAY raw_tail surface=\(surfaceID) bytes=\(bytes?.count ?? -1) seq=\(replaySeq ?? 0)")
                }
                if let replaySeq {
                    self.markTerminalBytesDelivered(surfaceID: surfaceID, endSeq: replaySeq)
                }
                // A render-grid replay (cold attach OR deeper-scrollback fetch) is
                // a full snapshot that re-flows scrollback into the local surface.
                // Deliver its metadata (scrollback depth + active screen) and its
                // bytes as ONE ordered element so the view classifies this exact
                // snapshot (deeper-fetch result vs cold attach) and applies any
                // scroll restore around this snapshot's own bytes, never around an
                // interleaved live frame.
                if let renderGrid {
                    self.deliverTerminalFrame(renderGrid, bytes: deliverBytes ?? Data())
                    return
                }
                guard let deliverBytes, !deliverBytes.isEmpty else {
                    return
                }
                self.deliverTerminalBytes(deliverBytes, surfaceID: surfaceID)
            } catch {
                mobileShellLog.error("CMUX_REPLAY failed surface=\(surfaceID, privacy: .public) error=\(String(describing: error), privacy: .public)")
                // The replay request is the view-only/foreground-resume path. A
                // definitive auth failure here (after the RPC layer's
                // force-refresh-and-retry already gave up) must drive the re-auth
                // prompt instead of silently leaving a stale frame.
                guard self.remoteClient === client else { return }
                _ = self.disconnectForAuthorizationFailureIfNeeded(error)
            }
        }
    }
}
