import CMUXAgentLaunch
import CmuxTerminal
import CMUXMobileCore
import Foundation

extension TerminalController {
    /// `surface.input_state`: whether typing into a terminal could disturb a
    /// human's input. Reports the agent's lifecycle and what its prompt area
    /// holds on screen (`empty`, `draft`, `dialog`, or `unknown` when no agent
    /// prompt is recognized). `cmux send` checks this before typing.
    ///
    /// Takes `surface_id`, or `workspace_id` for that workspace's focused
    /// surface. The draft text itself is never returned, only its length.
    nonisolated func v2SurfaceInputState(params: [String: Any]) -> V2CallResult {
        v2MainSync { self.v2RefreshKnownRefs() }
        let requestedSurface = v2UUID(params, "surface_id")
        let tabManager = requestedSurface == nil ? v2ResolveTabManager(params: params) : nil
        return v2MainSync { () -> V2CallResult in
            let workspace: Workspace
            let surfaceId: UUID
            if let requestedSurface {
                guard let located = AppDelegate.shared?.workspaceContainingPanel(
                    panelId: requestedSurface,
                    preferredWorkspaceId: self.v2UUID(params, "workspace_id")
                ) else {
                    return .err(code: "not_found", message: self.controlSurfaceNotFoundMessage(), data: nil)
                }
                workspace = located.workspace
                surfaceId = requestedSurface
            } else {
                guard let tabManager,
                      let resolved = self.v2ResolveWorkspace(params: params, tabManager: tabManager),
                      let focused = resolved.focusedPanelId else {
                    return .err(code: "not_found", message: self.controlSurfaceNotFoundMessage(), data: nil)
                }
                workspace = resolved
                surfaceId = focused
            }

            let lifecycle = workspace.agentHibernationLifecycleState(panelId: surfaceId, fallback: nil)
            let hasAgent = workspace.agentLifecycleStatesByPanelId[surfaceId]?.isEmpty == false
            var payload: [String: Any] = [
                "surface_id": surfaceId.uuidString,
                "workspace_id": workspace.id.uuidString,
                "agent": hasAgent,
                "lifecycle": lifecycle.rawValue,
                "waiting_on_human": lifecycle == .needsInput,
            ]
            guard let panel = workspace.panels[surfaceId] as? TerminalPanel else {
                payload["terminal"] = false
                payload["state"] = "unknown"
                return .ok(payload)
            }
            payload["terminal"] = true
            let screen = Self.agentPromptInputState(of: panel.surface)
            // Only the screen decides, and only for a surface that runs an
            // agent: the prompt glyphs and key hints also show up in other
            // programs' output, and the lifecycle can stay `needsInput` after
            // an interrupt or an API error, when typing is how to recover.
            var blocks = false
            switch screen {
            case .unknown:
                payload["state"] = "unknown"
            case .empty:
                payload["state"] = "empty"
            case .draft(let text):
                payload["state"] = "draft"
                payload["draft_length"] = text.count
                blocks = hasAgent
            case .dialog:
                payload["state"] = "dialog"
                blocks = hasAgent
            }
            payload["blocks_typing"] = blocks
            return .ok(payload)
        }
    }

    /// Reads the visible screen through the render-grid export, keeping each
    /// span's faint attribute so placeholders don't read as drafts.
    @MainActor
    static func agentPromptInputState(of surface: TerminalSurface) -> AgentPromptInputState {
        // The active screen, not the viewport: a human scrolled up in the
        // pane still has their draft at the bottom.
        guard let frame = surface.mobileRenderGridFrame(
            stateSeq: 0,
            includeTheme: false,
            anchor: .screen
        )?.frame else {
            return .unknown
        }
        var faintStyles = Set<Int>()
        for style in frame.styles where style.faint {
            faintStyles.insert(style.id)
        }
        var rows = Array(repeating: [AgentPromptScreenSpan](), count: max(frame.rows, 0))
        for span in frame.rowSpans where span.row >= 0 && span.row < rows.count {
            rows[span.row].append(AgentPromptScreenSpan(
                column: span.column,
                text: span.text,
                faint: faintStyles.contains(span.styleID)
            ))
        }
        return AgentPromptInputState(screenRows: rows)
    }
}
