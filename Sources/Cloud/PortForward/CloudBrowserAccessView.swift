import CmuxCloud
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
                    if state.isDesktop && !state.showsPage && state.failureMessage == nil {
                        CloudBrowserConnectionCard(
                            address: state.remoteURL?.absoluteString ?? "",
                            message: nil,
                            onRetry: nil
                        )
                    } else if state.showsPage || state.failureMessage == nil {
                        VStack(spacing: 0) {
                            if state.isDesktop && !state.desktopConnected && state.failureMessage == nil {
                                ProgressView(String(localized: "cloud.display.connecting", defaultValue: "Connecting to Cloud display…"))
                                    .controlSize(.small).padding(12)
                                    .accessibilityIdentifier("CloudDisplayConnecting")
                            }
                            content()
                        }
                    } else {
                        CloudBrowserConnectionCard(
                            address: state.remoteURL?.absoluteString ?? "",
                            message: state.failureMessage ?? model.failureMessage,
                            onRetry: {
                                _ = panel.reload()
                            }
                        )
                    }
                }
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
        let state = panel.cloudAccess
        return state.unavailable != nil
            || state.failureMessage != nil
            || (state.isDesktop && !state.showsPage)
    }
}
