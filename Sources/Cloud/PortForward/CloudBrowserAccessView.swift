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
                        .ghosttyDialogTheme()
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
                        .ghosttyDialogTheme()
                    }
                }
            } else if let message = state.starting {
                ProgressView(message)
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityIdentifier("CloudDisplayStarting")
            } else if let message = state.unavailable {
                CloudBrowserConnectionCard(address: "", message: message, onRetry: state.unavailableRetryAction)
                    .ghosttyDialogTheme()
            } else {
                content()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: backgroundColor))
        .accessibilityIdentifier("CloudBrowserAccess")
        .overlay {
            // An in-pane card rather than a system alert, which cannot take
            // the Ghostty theme colors.
            if isVisibleInUI && state.showsFailureAlert {
                CloudFailureCard(
                    title: String(localized: "cloud.overlay.error.title", defaultValue: "Cloud session unavailable"),
                    detail: state.failureMessage ?? "",
                    copyableText: state.failureMessage ?? "",
                    style: .dialog,
                    onRetry: state.model == nil ? nil : { _ = panel.reload() },
                    onDismiss: { state.dismissFailure() }
                )
                .frame(maxWidth: 320)
                .padding(12)
            }
        }
        .onChange(of: showsNativeContent, initial: true) { _, shown in
            if shown { BrowserWindowPortalRegistry.hide(webView: panel.webView, source: "cloudConnection") }
        }
    }

    private var showsNativeContent: Bool {
        let state = panel.cloudAccess
        return state.unavailable != nil
            || state.starting != nil
            || state.failureMessage != nil
            || (state.isDesktop && !state.showsPage)
    }
}
