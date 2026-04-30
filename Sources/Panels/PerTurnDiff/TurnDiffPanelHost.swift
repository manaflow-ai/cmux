import SwiftUI
import WebKit
import Combine

/// Right-sidebar content view for the per-turn diff panel.
/// Hosts a WKWebView loading TurnDiffWebViewBundle.html and bridges to the per-workspace
/// TurnCheckpointManager via TurnDiffMessageHandler + cmuxDispatchTurnDiff.
struct TurnDiffPanelHost: View {
    @ObservedObject var workspace: Workspace

    var body: some View {
        TurnDiffWebViewWrapper(workspace: workspace)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(red: 0.086, green: 0.086, blue: 0.094))
    }
}

private struct TurnDiffWebViewWrapper: NSViewRepresentable {
    let workspace: Workspace

    func makeCoordinator() -> Coordinator {
        Coordinator(workspaceId: workspace.id)
    }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let coord = context.coordinator
        let handler = TurnDiffMessageHandler { [weak coord] msg in
            coord?.handle(message: msg)
        }
        config.userContentController.add(handler, name: TurnDiffMessageHandler.handlerName)

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.setValue(false, forKey: "drawsBackground")
        coord.webView = webView
        coord.attachManagerCallbacks()
        webView.loadHTMLString(TurnDiffWebViewBundle.html, baseURL: Bundle.main.resourceURL)
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        if context.coordinator.workspaceId != workspace.id {
            context.coordinator.detachManagerCallbacks()
            context.coordinator.workspaceId = workspace.id
            context.coordinator.attachManagerCallbacks()
        }
    }

    static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
        coordinator.detachManagerCallbacks()
        nsView.configuration.userContentController.removeScriptMessageHandler(
            forName: TurnDiffMessageHandler.handlerName
        )
    }

    @MainActor
    final class Coordinator {
        weak var webView: WKWebView?
        var workspaceId: UUID

        init(workspaceId: UUID) {
            self.workspaceId = workspaceId
        }

        func attachManagerCallbacks() {
            guard let mgr = TurnCheckpointRegistry.shared.manager(for: workspaceId) else { return }
            mgr.onDiffChanged = { [weak self] diff in
                self?.webView?.cmuxDispatchTurnDiff(eventName: "cmux:diff-changed", detail: diff)
            }
            mgr.onLiveDiffChanged = { [weak self] diff in
                self?.webView?.cmuxDispatchTurnDiff(eventName: "cmux:diff-changed", detail: diff)
            }
            mgr.onStatusChanged = { [weak self] status in
                self?.webView?.cmuxDispatchTurnDiff(eventName: "cmux:status-changed", detail: status)
            }
        }

        func detachManagerCallbacks() {
            if let mgr = TurnCheckpointRegistry.shared.manager(for: workspaceId) {
                mgr.onDiffChanged = nil
                mgr.onLiveDiffChanged = nil
                mgr.onStatusChanged = nil
            }
        }

        func handle(message: TurnDiffBridgeMessage) {
            switch message {
            case .ready, .diffRequest:
                guard let mgr = TurnCheckpointRegistry.shared.manager(for: workspaceId),
                      let cwd = mgr.workspaceCwd, !cwd.isEmpty else {
                    // No manager / no cwd → leave empty state visible
                    return
                }
                let diff = (try? TurnCheckpointStore.diffAgainstWorkingTree(
                    session: workspaceId, in: cwd
                )) ?? ""
                webView?.cmuxDispatchTurnDiff(eventName: "cmux:diff-changed", detail: diff)
            }
        }
    }
}
