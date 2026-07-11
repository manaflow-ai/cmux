public import CMUXMobileCore
import CmuxMobileRPC
public import Foundation
import OSLog

private let terminalScrollDeliveryLog = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "dev.cmux.ios",
    category: "mobile-shell"
)

extension MobileShellComposite {
    /// Mounts the single optimistic-scroll owner for a rendered surface. The
    /// closures are the only bridge into the UIKit/Ghostty view; RPC ordering,
    /// prefetch policy, input epochs, and authoritative reconciliation remain
    /// owned by the session stored here.
    @discardableResult
    public func mountTerminalScrollSession(
        surfaceID: String,
        applyLocal: @escaping @MainActor @Sendable (_ runs: [MobileTerminalScrollRun]) async -> Bool,
        cancelLocal: @escaping @MainActor @Sendable () -> Void
    ) -> UUID {
        let epoch = advanceTerminalInteractionEpoch(surfaceID: surfaceID)
        deferredTerminalRenderGridEventsBySurfaceID.removeValue(forKey: surfaceID)
        if let existing = terminalScrollSessionsBySurfaceID.removeValue(forKey: surfaceID) {
            existing.cancelForUnmount(nextEpoch: epoch)
        }
        let session = TerminalScrollSession(
            surfaceID: surfaceID,
            interactionEpoch: epoch,
            applyLocal: applyLocal,
            cancelLocal: cancelLocal,
            sendRemote: { [weak self] request in
                await self?.performTerminalScroll(request)
            },
            prepareIntent: { [weak self] in
                self?.prepareTerminalOutputForOptimisticScroll(surfaceID: surfaceID)
            },
            deliverAuthoritative: { [weak self] frame, epoch, revision in
                self?.deliverAuthoritativeTerminalRenderGrid(
                    frame,
                    expectedSurfaceID: surfaceID,
                    source: "scroll_reconcile",
                    scrollReconciliation: TerminalScrollReconciliation(
                        interactionEpoch: epoch,
                        clientRevision: revision
                    )
                ) ?? false
            },
            acceptAuthoritativeRevision: { [weak self] revision in
                self?.acceptTerminalRenderRevision(revision, surfaceID: surfaceID)
            },
            reconciliationDidComplete: { [weak self] in
                self?.flushDeferredTerminalRenderGridEvent(surfaceID: surfaceID)
            },
            requestReplay: { [weak self] epoch in
                self?.requestTerminalReplay(
                    surfaceID: surfaceID,
                    interactionEpoch: epoch
                )
            },
            advanceEpoch: { [weak self] in
                self?.advanceTerminalInteractionEpoch(surfaceID: surfaceID) ?? 0
            }
        )
        terminalScrollSessionsBySurfaceID[surfaceID] = session
        return session.token
    }

    public func unmountTerminalScrollSession(surfaceID: String, token: UUID) {
        guard let session = terminalScrollSessionsBySurfaceID[surfaceID],
              session.token == token else {
            return
        }
        terminalScrollSessionsBySurfaceID.removeValue(forKey: surfaceID)
        deferredTerminalRenderGridEventsBySurfaceID.removeValue(forKey: surfaceID)
        session.cancelForUnmount(nextEpoch: advanceTerminalInteractionEpoch(surfaceID: surfaceID))
    }

    /// Submits one display-link-coalesced UIKit delta. This is synchronous on
    /// the main actor so Task scheduling cannot reorder gesture intent before
    /// the per-surface owner stamps it.
    public func scrollTerminal(surfaceID: String, lines: Double, col: Int, row: Int) {
        terminalScrollSessionsBySurfaceID[surfaceID]?.submit(
            lines: lines,
            col: col,
            row: row
        )
    }

    public func terminalScrollInteractionDidBegin(surfaceID: String) {
        terminalScrollSessionsBySurfaceID[surfaceID]?.interactionDidBegin()
    }

    public func terminalScrollInteractionDidEnd(surfaceID: String) {
        terminalScrollSessionsBySurfaceID[surfaceID]?.interactionDidEnd()
    }

    @discardableResult
    func invalidateTerminalScrollForInput(surfaceID: String) -> UInt64? {
        prepareTerminalOutputForOptimisticScroll(surfaceID: surfaceID)
        deferredTerminalRenderGridEventsBySurfaceID.removeValue(forKey: surfaceID)
        return terminalScrollSessionsBySurfaceID[surfaceID]?.invalidateForInput()
    }

    @discardableResult
    func invalidateTerminalScrollForRecovery(surfaceID: String) -> UInt64? {
        deferredTerminalRenderGridEventsBySurfaceID.removeValue(forKey: surfaceID)
        return terminalScrollSessionsBySurfaceID[surfaceID]?.invalidateForRecovery()
    }

    func currentTerminalInteractionEpoch(surfaceID: String) -> UInt64? {
        terminalScrollSessionsBySurfaceID[surfaceID]?.interactionEpoch
            ?? terminalInteractionEpochsBySurfaceID[surfaceID]
    }

    func advanceTerminalInteractionEpoch(surfaceID: String) -> UInt64 {
        var next = (terminalInteractionEpochsBySurfaceID[surfaceID] ?? 0) &+ 1
        if next == 0 { next = 1 }
        terminalInteractionEpochsBySurfaceID[surfaceID] = next
        return next
    }

    private func performTerminalScroll(_ request: TerminalScrollRequest) async -> TerminalScrollResponse? {
        guard let client = remoteClient,
              let workspaceID = workspaceID(forTerminalID: request.surfaceID) else {
            return nil
        }
        do {
            let remoteWorkspaceID = remoteWorkspaceID(for: workspaceID)
            var params: [String: Any] = [
                "workspace_id": remoteWorkspaceID.rawValue,
                "surface_id": request.surfaceID,
                "client_id": clientID,
                "interaction_epoch": Int(clamping: request.interactionEpoch),
                "client_scroll_revision": Int(clamping: request.clientRevision),
                "delta_lines": request.lines,
                "delta_runs": request.directionalRuns.map { run in
                    [
                        "lines": run.lines,
                        "col": run.col,
                        "row": run.row,
                    ] as [String: Any]
                },
                "col": request.col,
                "row": request.row,
            ]
            if let window = request.prefetchWindow {
                params["prefetch_before_rows"] = window.rowsBeforeViewport
                params["prefetch_after_rows"] = window.rowsAfterViewport
                // Compatibility with hosts predating bidirectional windows.
                params["max_scrollback_rows"] = max(
                    window.rowsBeforeViewport,
                    window.rowsAfterViewport
                )
            }
            let data = try await client.sendRequest(MobileCoreRPCClient.requestData(
                method: "mobile.terminal.scroll",
                params: params
            ))
            guard remoteClient === client else { return nil }
            let payload = try MobileTerminalScrollResponse.decode(data)
            return TerminalScrollResponse(
                accepted: payload.accepted ?? true,
                interactionEpoch: payload.interactionEpoch ?? request.interactionEpoch,
                clientRevision: payload.clientScrollRevision ?? request.clientRevision,
                renderRevision: payload.renderRevision ?? payload.renderGrid?.renderRevision,
                renderGrid: payload.renderGrid
            )
        } catch {
            terminalScrollDeliveryLog.error("scroll transaction failed surface=\(request.surfaceID, privacy: .public) epoch=\(request.interactionEpoch, privacy: .public) revision=\(request.clientRevision, privacy: .public) error=\(String(describing: error), privacy: .public)")
            return nil
        }
    }
}
