import SwiftUI
import WebKit
import Combine

/// Right-sidebar content view for the per-turn diff panel.
/// Hosts a WKWebView loading TurnDiffWebViewBundle.html and bridges to the per-workspace
/// TurnCheckpointManager via TurnDiffMessageHandler + cmuxDispatchTurnDiff.
struct TurnDiffPanelHost: View {
    let workspaceId: UUID

    var body: some View {
        TurnDiffWebViewWrapper(workspaceId: workspaceId)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(red: 0.086, green: 0.086, blue: 0.094))
    }
}

private struct TurnDiffWebViewWrapper: NSViewRepresentable {
    let workspaceId: UUID

    func makeCoordinator() -> Coordinator {
        Coordinator(workspaceId: workspaceId)
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
        if context.coordinator.workspaceId != workspaceId {
            context.coordinator.detachManagerCallbacks()
            context.coordinator.workspaceId = workspaceId
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
            mgr.onMultiDiffChanged = { [weak self] repos in
                self?.dispatchMultiDiff(repos)
            }
            mgr.onLiveMultiDiffChanged = { [weak self] repos in
                self?.dispatchMultiDiff(repos)
            }
            mgr.onStatusChanged = { [weak self] status in
                self?.webView?.cmuxDispatchTurnDiff(eventName: "cmux:status-changed", detail: status)
            }
            mgr.onRootChanged = { [weak self] newRoot, hasRoot, observedCwd in
                guard let self else { return }
                if hasRoot, let root = newRoot {
                    self.webView?.cmuxDispatchTurnDiff(
                        eventName: "turnDiff:rootChanged",
                        detail: ["root": root]
                    )
                } else {
                    self.webView?.cmuxDispatchTurnDiff(
                        eventName: "turnDiff:noGitRoot",
                        detail: ["cwd": observedCwd ?? "(none)"]
                    )
                }
            }

            // Push the current root + initial multi-diff immediately so a
            // freshly-mounted panel renders the right state without waiting
            // for the next pwd change or turn boundary.
            if let root = mgr.currentRoot {
                webView?.cmuxDispatchTurnDiff(
                    eventName: "turnDiff:rootChanged",
                    detail: ["root": root]
                )
            } else {
                webView?.cmuxDispatchTurnDiff(
                    eventName: "turnDiff:noGitRoot",
                    detail: ["cwd": "(none)"]
                )
            }
            dispatchMultiDiff(mgr.computeMultiDiff())
        }

        func detachManagerCallbacks() {
            if let mgr = TurnCheckpointRegistry.shared.manager(for: workspaceId) {
                mgr.onMultiDiffChanged = nil
                mgr.onLiveMultiDiffChanged = nil
                mgr.onStatusChanged = nil
                mgr.onRootChanged = nil
            }
        }

        func handle(message: TurnDiffBridgeMessage) {
            switch message {
            case .ready, .diffRequest:
                guard let mgr = TurnCheckpointRegistry.shared.manager(for: workspaceId) else {
                    webView?.cmuxDispatchTurnDiff(
                        eventName: "turnDiff:noGitRoot",
                        detail: ["cwd": "(none)"]
                    )
                    dispatchMultiDiff([])
                    return
                }
                if let root = mgr.currentRoot, !root.isEmpty {
                    webView?.cmuxDispatchTurnDiff(
                        eventName: "turnDiff:rootChanged",
                        detail: ["root": root]
                    )
                } else {
                    webView?.cmuxDispatchTurnDiff(
                        eventName: "turnDiff:noGitRoot",
                        detail: ["cwd": "(none)"]
                    )
                }
                dispatchMultiDiff(mgr.computeMultiDiff())
            }
        }

        /// Serialize one RepoDiff per visited root and ship it as the new
        /// `cmux:diff-changed` payload `{ repos: [...] }`. The React side
        /// uses this to render one collapsible group per repo.
        private func dispatchMultiDiff(_ repos: [TurnCheckpointManager.RepoDiff]) {
            let payload: [[String: Any]] = repos.map { repo in
                [
                    "root": repo.root,
                    "diff": repo.diff,
                    "isActive": repo.isActive
                ]
            }
            webView?.cmuxDispatchTurnDiff(
                eventName: "cmux:diff-changed",
                detail: ["repos": payload]
            )
        }
    }
}
