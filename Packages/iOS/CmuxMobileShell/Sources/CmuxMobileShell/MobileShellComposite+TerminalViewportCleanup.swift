internal import CMUXMobileCore
internal import CmuxMobileDiagnostics
internal import CmuxMobileRPC
internal import CmuxMobileShellModel
internal import Foundation

extension MobileShellComposite {
    /// Tell the Mac to drop this device's viewport pin for a surface (on
    /// detach). Fire-and-forget; the Mac also clears on connection close.
    public func clearTerminalViewport(surfaceID: String) {
        recordAppEvent(.terminalViewportClearStarted, correlationID: surfaceID)
        let sequenceKey = MobileTerminalViewportSequenceKey(
            ownerKey: foregroundMacKey,
            surfaceID: surfaceID
        )
        terminalViewportPreparationGenerationsBySequenceKey.removeValue(
            forKey: sequenceKey
        )
        terminalViewportDeferredColdReplayGenerationsBySequenceKey.removeValue(
            forKey: sequenceKey
        )
        let workspaceID = workspaceID(forTerminalID: surfaceID)
        // A clear releases the presentation's full local viewport lease. Any
        // replay, input, or paste that races after this point must not carry
        // the released dimensions with the newer clear generation and re-pin
        // the Mac surface.
        if let workspaceID {
            reportedViewportSizesByTerminalKey.removeValue(forKey: MobileTerminalViewportKey(
                workspaceID: workspaceID,
                terminalID: MobileTerminalPreview.ID(rawValue: surfaceID)
            ))
        } else {
            // A surface can disappear from the workspace snapshot before its
            // teardown callback runs. There is no route for the clear RPC in
            // that case, so discard any colliding local entries as a last
            // line of defence against a later replay piggyback.
            reportedViewportSizesByTerminalKey = reportedViewportSizesByTerminalKey.filter {
                $0.key.terminalID.rawValue != surfaceID
            }
        }
        // The generation entry deliberately outlives the surface: it is the
        // monotonic fence that keeps a still-in-flight viewport report from
        // applying after detach and blocks generation reuse across re-attach.
        // Warm focus swaps keep the peer connection alive, so its fence must
        // outlive the focused role. The account boundary clears all sequences.
        let clearGeneration =
            (viewportReportGenerationsBySequenceKey[sequenceKey] ?? 0) + 1
        viewportReportGenerationsBySequenceKey[sequenceKey] = clearGeneration
        effectiveViewportSizesBySurfaceID.removeValue(forKey: surfaceID)
        reportedTerminalViewportSizesBySurfaceID.removeValue(forKey: surfaceID)
        guard let client = remoteClient,
              let workspaceID else {
            recordAppEvent(
                .terminalViewportClearFailed,
                correlationID: surfaceID,
                failure: .noRoute
            )
            return
        }
        let id = clientID
        let remoteWorkspaceID = remoteWorkspaceID(for: workspaceID)
        Task { @MainActor in
            do {
                let request = try MobileCoreRPCClient.requestData(
                    method: "mobile.terminal.viewport",
                    params: [
                        "workspace_id": remoteWorkspaceID.rawValue,
                        "surface_id": surfaceID,
                        "client_id": id,
                        "clear": true,
                        "viewport_generation": Int(clamping: clearGeneration),
                    ]
                )
                _ = try await client.sendRequest(request)
                self.recordAppEvent(
                    .terminalViewportClearSucceeded,
                    correlationID: surfaceID
                )
            } catch {
                self.recordAppEvent(
                    .terminalViewportClearFailed,
                    correlationID: surfaceID,
                    failure: DiagnosticFailureKind.classify(error)
                )
            }
        }
    }
}
