import AppKit
import Foundation

/// A workspace pane hosting the `/agent-chat` web surface for one resolved
/// agent session.
///
/// The panel owns the hosted ``AgentChatWebViewController`` (the WKWebView,
/// the `agentChat` bridge, and the spawned daemon child), so the daemon
/// child's lifetime is bound to the panel: closing the pane terminates it.
@MainActor
final class AgentChatPanel: Panel {
    let id = UUID()
    let panelType: PanelType = .agentChat
    private(set) var workspaceId: UUID

    /// The resolved agent session this pane mirrors.
    private(set) var resolution: AgentChatTranscriptResolver.Resolution

    /// The hosted webview controller; created once per panel and re-parented
    /// by the SwiftUI representable as layout churns.
    let chatViewController = AgentChatWebViewController()

    var displayTitle: String {
        String(localized: "agentChat.panel.title", defaultValue: "Agent Chat")
    }

    var displayIcon: String? { "text.bubble" }

    init(workspaceId: UUID, resolution: AgentChatTranscriptResolver.Resolution) {
        self.workspaceId = workspaceId
        self.resolution = resolution
        chatViewController.present(resolution: resolution)
    }

    /// Whether this pane already mirrors the given resolved session.
    func mirrors(_ other: AgentChatTranscriptResolver.Resolution) -> Bool {
        resolution.provider == other.provider && resolution.sessionId == other.sessionId
    }

    /// Retargets the pane at another resolved session; the surface reloads and
    /// restarts from `chat.init` for the new target.
    func retarget(_ newResolution: AgentChatTranscriptResolver.Resolution) {
        resolution = newResolution
        chatViewController.present(resolution: newResolution)
    }

    func updateWorkspaceId(_ newWorkspaceId: UUID) {
        workspaceId = newWorkspaceId
    }

    func focus() {
        let view = chatViewController.view
        view.window?.makeFirstResponder(view)
    }

    func unfocus() {}

    /// Terminates the daemon child; the panel never outlives its chat surface.
    func close() {
        chatViewController.teardownForClose()
    }

    func triggerFlash(reason: WorkspaceAttentionFlashReason) {
        _ = reason
    }
}
