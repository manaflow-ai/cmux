import AppKit
import CmuxTerminal
import Foundation

extension GhosttySurfaceScrollView: AgentTurnTerminalViewport {
    /// Attaches the turn rail for `surfaceID`, following the agent session
    /// the source reports for it, while the preview is on
    /// (``AgentTurnRailPreview``); while it is off, removes any rail.
    /// Idempotent for the same surface.
    ///
    /// - Parameters:
    ///   - surfaceID: The terminal surface this view hosts.
    ///   - source: The outline source; `nil` leaves the rail as it is.
    func installAgentTurnRail(surfaceID: UUID, source: (any AgentTurnOutlineSource)?) {
        AgentTurnRailPreview.startApplyingChanges()
        guard AgentTurnRailPreview.isOptedIn() else {
            removeAgentTurnRail()
            return
        }
        // The transcript service is wired after early session restore; keep
        // whatever is attached until it exists (see
        // `installAgentTurnRailIfNeeded()`).
        guard let source else { return }
        if let host = agentTurnRailHost, host.model.surfaceID == surfaceID {
            host.model.start(source: source, viewport: self)
            return
        }
        agentTurnRailHost?.tearDown()
        let model = AgentTurnRailModel(surfaceID: surfaceID)
        let host = AgentTurnRailHost(model: model, container: self, scrollTarget: agentTurnRailScrollTarget)
        model.onPresentationChange = { [weak self] in
            // Reserve or release the gutter now so the terminal reflows once.
            _ = self?.reconcileGeometryNow()
        }
        agentTurnRailHost = host
        model.start(source: source, viewport: self)
    }

    /// Late attach for surfaces configured before the transcript service
    /// existed. Cheap enough for the scrollbar update path.
    func installAgentTurnRailIfNeeded() {
        guard agentTurnRailHost == nil,
              AgentTurnRailPreview.isOptedIn(),
              let surfaceID = surfaceView.terminalSurface?.id,
              let source = TerminalController.shared.agentChatTranscriptService else {
            return
        }
        installAgentTurnRail(surfaceID: surfaceID, source: source)
    }

    /// Applies the preview setting now: attaches the rail when it is on,
    /// removes it and releases its gutter when it is off.
    func reconcileAgentTurnRail() {
        if AgentTurnRailPreview.isOptedIn() {
            installAgentTurnRailIfNeeded()
        } else {
            removeAgentTurnRail()
        }
    }

    /// Stops the rail's transcript observation and gives its gutter back to
    /// the terminal.
    private func removeAgentTurnRail() {
        guard let host = agentTurnRailHost else { return }
        host.tearDown()
        agentTurnRailHost = nil
        _ = reconcileGeometryNow()
    }

    /// The rail model for this surface, when a rail is attached.
    var agentTurnRailModel: AgentTurnRailModel? {
        agentTurnRailHost?.model
    }

    func agentTurnRailGeometry() -> NotificationScrollRestoreGeometry? {
        surfaceView.authoritativeScrollbarGeometry()
    }

    var agentTurnRailIsOnScreen: Bool {
        window != nil && !isHiddenOrHasHiddenAncestor && bounds.width > 0 && bounds.height > 0
    }

    func agentTurnRailScreenRows() -> String? {
        surfaceView.terminalSurface?.readScreenRows()
    }

    func agentTurnRailScroll(toRow row: Int, revision: UInt64, isAtBottom: Bool) -> Bool {
        let previousIntent = prepareExplicitViewportRestore(isAtBottom: isAtBottom)
        guard surfaceView.scrollToRow(row, ifRowSpaceRevisionMatches: revision) != nil else {
            rollbackExplicitViewportRestore(to: previousIntent)
            return false
        }
        return true
    }
}
