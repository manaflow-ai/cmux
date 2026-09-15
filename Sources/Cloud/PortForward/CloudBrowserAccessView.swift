import AppKit
import SwiftUI

/// Native UI in the browser content area. Explicitly hide retained portal
/// content while showing controls; dismantling its SwiftUI host retains it.
struct CloudBrowserAccessView<Content: View>: View {
    let panel: BrowserPanel
    let backgroundColor: NSColor
    @ViewBuilder let content: () -> Content
    var body: some View {
        let state = panel.cloudAccess
        Group {
            if let model = state.model {
                Group {
                    if state.showsPage { content() } else {
                        CloudBrowserConnectionCard(
                            address: state.remoteURL?.absoluteString ?? "",
                            phase: model.phase,
                            message: state.error ?? model.failureMessage,
                            onRetry: {
                                state.retry()
                                navigateIfReady()
                            }
                        )
                    }
                }
                .task(id: model.phase) { navigateIfReady() }
                .task(id: state.remoteURL) { navigateIfReady() }
            } else if let message = state.unavailable {
                CloudBrowserConnectionCard(address: "", phase: .failed(message), message: message, onRetry: nil)
            } else {
                content()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: backgroundColor))
        .accessibilityIdentifier("CloudBrowserAccess")
        .onChange(of: showsNativeContent, initial: true) { _, shown in
            if shown { BrowserWindowPortalRegistry.hide(webView: panel.webView, source: "cloudConnection") }
        }
    }

    private var showsNativeContent: Bool {
        panel.cloudAccess.unavailable != nil ||
            (panel.cloudAccess.model != nil && !panel.cloudAccess.showsPage)
    }

    private func navigateIfReady() {
        guard let url = panel.cloudAccess.nextURL() else {
            if panel.cloudAccess.model?.isReady != true { panel.webView.stopLoading() }
            return
        }
        _ = panel.navigate(to: url)
    }
}
