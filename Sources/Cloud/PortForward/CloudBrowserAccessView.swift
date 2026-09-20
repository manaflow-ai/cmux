import AppKit
import SwiftUI

/// Native UI in the browser content area. Explicitly hide retained portal
/// content while showing controls; dismantling its SwiftUI host retains it.
struct CloudBrowserAccessView<Content: View>: View {
    let panel: BrowserPanel
    let backgroundColor: NSColor
    let isVisibleInUI: Bool
    @ViewBuilder let content: () -> Content
    var body: some View {
        let state = panel.cloudAccess
        Group {
            if let model = state.model {
                Group {
                    if state.showsPage || state.failureMessage == nil { content() } else {
                        CloudBrowserConnectionCard(
                            address: state.remoteURL?.absoluteString ?? "",
                            message: state.error ?? model.failureMessage,
                            onRetry: {
                                _ = panel.reload()
                                navigateIfReady()
                            }
                        )
                    }
                }
                .task(id: model.phase) { navigateIfReady() }
                .task(id: state.remoteURL) { navigateIfReady() }
            } else if let message = state.unavailable {
                CloudBrowserConnectionCard(address: "", message: message, onRetry: state.unavailableRetryAction)
            } else {
                content()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: backgroundColor))
        .accessibilityIdentifier("CloudBrowserAccess")
        .alert(
            String(localized: "cloud.overlay.error.title", defaultValue: "Cloud session unavailable"),
            isPresented: Binding(
                get: { isVisibleInUI && state.showsFailureAlert },
                set: { if !$0 { state.dismissFailure() } }
            )
        ) {
            if state.model != nil {
                Button(String(localized: "common.retry", defaultValue: "Retry")) {
                    _ = panel.reload()
                    navigateIfReady()
                }
            }
            Button(String(localized: "common.close", defaultValue: "Close"), role: .cancel) { state.dismissFailure() }
        } message: {
            Text(state.failureMessage ?? "")
        }
        .onChange(of: showsNativeContent, initial: true) { _, shown in
            if shown { BrowserWindowPortalRegistry.hide(webView: panel.webView, source: "cloudConnection") }
        }
    }

    private var showsNativeContent: Bool {
        panel.cloudAccess.unavailable != nil || panel.cloudAccess.failureMessage != nil
    }

    private func navigateIfReady() {
        guard let url = panel.cloudAccess.nextURL() else { return }
        _ = panel.navigate(to: url)
    }
}
