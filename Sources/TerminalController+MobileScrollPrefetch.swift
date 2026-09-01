import CMUXMobileCore
import CmuxTerminal
import Foundation

extension TerminalController {
    /// Scrollback rows included in a cold-attach render-grid replay snapshot.
    /// Live render-grid events carry no scrollback; the phone keeps its own
    /// bounded Ghostty scrollback mirror and scrolls that mirror locally while
    /// the Mac remains authoritative.
    nonisolated static let mobileReplayScrollbackLineBudget = 240

    /// Larger history window returned only on explicit mobile scroll prefetch
    /// requests, keeping ordinary scroll RPCs small.
    nonisolated static let mobileScrollPrefetchScrollbackLineBudget = 600

    func mobileTerminalRenderGridFrame(
        terminalPanel: TerminalPanel,
        surfaceID: UUID,
        seq: UInt64,
        scrollbackLines: Int = TerminalController.mobileReplayScrollbackLineBudget,
        anchor: MobileTerminalRenderGridFrame.Anchor = .viewport,
        adoptReplayBaseline: Bool = true,
        recordProducerIdentity: Bool = true
    ) -> MobileTerminalRenderGridFrame? {
        mobileTerminalRenderGridFrame(
            surface: terminalPanel.surface,
            surfaceID: surfaceID,
            seq: seq,
            scrollbackLines: scrollbackLines,
            anchor: anchor,
            adoptReplayBaseline: adoptReplayBaseline,
            recordProducerIdentity: recordProducerIdentity
        )
    }

    private func mobileTerminalRenderGridFrame(
        surface: TerminalSurface,
        surfaceID: UUID,
        seq: UInt64,
        scrollbackLines: Int,
        anchor: MobileTerminalRenderGridFrame.Anchor,
        adoptReplayBaseline: Bool = true,
        recordProducerIdentity: Bool = true
    ) -> MobileTerminalRenderGridFrame? {
        guard surfaceID == surface.id else { return nil }
        let renderCapture = MobileTerminalByteTee.shared.currentRenderCaptureIdentity(
            surfaceID: surfaceID,
            anchor: anchor
        )
        guard var frame = surface.mobileRenderGridFrame(
            stateSeq: seq,
            renderEpoch: renderCapture.epoch,
            renderRevision: renderCapture.revision,
            scrollbackLines: scrollbackLines,
            anchor: anchor
        )?.frame else { return nil }
        frame = MobileTerminalRenderObserver.shared.decorateReplayFrame(
            frame,
            advanceThemeRevision: recordProducerIdentity
        )
        let identity: (
            epoch: String,
            revision: UInt64,
            emissionRevision: UInt64
        )
        if recordProducerIdentity {
            identity = MobileTerminalByteTee.shared.recordRenderGridFrame(
                surfaceID: surfaceID,
                anchor: anchor,
                fullFrame: frame
            )
        } else {
            let current = MobileTerminalByteTee.shared.currentRenderCaptureIdentity(
                surfaceID: surfaceID,
                anchor: anchor
            )
            identity = (
                epoch: current.epoch,
                revision: current.revision,
                emissionRevision: current.emissionRevision
            )
        }
        frame.renderEpoch = identity.epoch
        frame.renderRevision = identity.revision
        frame.emissionRevision = identity.emissionRevision
        if adoptReplayBaseline {
            MobileTerminalRenderObserver.shared.adoptReplayBaseline(frame, surfaceID: surfaceID)
        }
        return frame
    }

    /// Captures a render grid from the canonical socket-bound runtime surface.
    func mobileTerminalRenderGridFrame(
        terminalTarget: ControlTerminalSocketTarget,
        surfaceID: UUID,
        seq: UInt64,
        scrollbackLines: Int = TerminalController.mobileReplayScrollbackLineBudget,
        anchor: MobileTerminalRenderGridFrame.Anchor = .viewport,
        adoptReplayBaseline: Bool = true,
        recordProducerIdentity: Bool = true
    ) -> MobileTerminalRenderGridFrame? {
        mobileTerminalRenderGridFrame(
            surface: terminalTarget.surface,
            surfaceID: surfaceID,
            seq: seq,
            scrollbackLines: scrollbackLines,
            anchor: anchor,
            adoptReplayBaseline: adoptReplayBaseline,
            recordProducerIdentity: recordProducerIdentity
        )
    }

    func mobileTerminalScrollResponsePayload(
        workspaceID: UUID,
        terminalPanel: TerminalPanel,
        surfaceID: UUID,
        params: [String: Any],
        adoptReplayBaseline: Bool = true,
        recordProducerIdentity: Bool = true
    ) -> [String: Any] {
        var payload: [String: Any] = [
            "workspace_id": workspaceID.uuidString,
            "surface_id": surfaceID.uuidString,
        ]
        let scrollbackRows = mobileScrollPrefetchRows(params: params)
        guard scrollbackRows > 0 else { return payload }
        let stateSeq = MobileTerminalByteTee.shared.currentSequence(surfaceID: surfaceID) ?? 0
        guard let renderGrid = mobileTerminalRenderGridFrame(
            terminalPanel: terminalPanel,
            surfaceID: surfaceID,
            seq: stateSeq,
            scrollbackLines: scrollbackRows,
            adoptReplayBaseline: adoptReplayBaseline,
            recordProducerIdentity: recordProducerIdentity
        ),
            renderGrid.activeScreen == .primary,
            let renderGridObject = try? renderGrid.jsonObject() else {
            return payload
        }
        payload["columns"] = renderGrid.columns
        payload["rows"] = renderGrid.rows
        payload["render_grid"] = renderGridObject
        payload["seq"] = renderGrid.stateSeq
        return payload
    }

    /// Builds a scroll response from the canonical socket-bound runtime.
    func mobileTerminalScrollResponsePayload(
        workspaceID: UUID,
        terminalTarget: ControlTerminalSocketTarget,
        surfaceID: UUID,
        params: [String: Any],
        adoptReplayBaseline: Bool = true,
        recordProducerIdentity: Bool = true
    ) -> [String: Any] {
        var payload: [String: Any] = [
            "workspace_id": workspaceID.uuidString,
            "surface_id": surfaceID.uuidString,
        ]
        let scrollbackRows = mobileScrollPrefetchRows(params: params)
        guard scrollbackRows > 0 else { return payload }
        let stateSeq = MobileTerminalByteTee.shared.currentSequence(surfaceID: surfaceID) ?? 0
        guard let renderGrid = mobileTerminalRenderGridFrame(
            terminalTarget: terminalTarget,
            surfaceID: surfaceID,
            seq: stateSeq,
            scrollbackLines: scrollbackRows,
            adoptReplayBaseline: adoptReplayBaseline,
            recordProducerIdentity: recordProducerIdentity
        ), renderGrid.activeScreen == .primary,
              let renderGridObject = try? renderGrid.jsonObject() else {
            return payload
        }
        payload["columns"] = renderGrid.columns
        payload["rows"] = renderGrid.rows
        payload["render_grid"] = renderGridObject
        payload["seq"] = renderGrid.stateSeq
        return payload
    }

    private func mobileScrollPrefetchRows(params: [String: Any]) -> Int {
        let requestedRows = (params["max_scrollback_rows"] as? NSNumber)?.intValue ?? 0
        return min(
            max(0, requestedRows),
            Self.mobileScrollPrefetchScrollbackLineBudget
        )
    }
}
