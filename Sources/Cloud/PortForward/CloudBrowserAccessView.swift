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
                            message: state.error ?? model.failureMessage ?? (model.phase == .needsVPN ? model.vpn.unavailableMessage : nil),
                            setupTitle: model.vpn.state == .awaitingApproval
                                ? String(localized: "cloud.vpn.setup.openSettings", defaultValue: "Open System Settings")
                                : String(localized: "machines.menu.setupVPN", defaultValue: "Set Up cmux VPN…"),
                            onSetup: {
                                if model.vpn.state == .awaitingApproval { SystemExtensionSettingsLink.open() }
                                else { Task { await model.vpn.connect() } }
                            },
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
                CloudBrowserConnectionCard(address: "", phase: .failed(message), message: message, setupTitle: String(localized: "machines.menu.setupVPN", defaultValue: "Set Up cmux VPN…"), onSetup: {
                    AppDelegate.shared?.openCloudVPNSetupWorkspace(preferredTabManager: AppDelegate.shared?.tabManagerFor(tabId: panel.workspaceId))
                }, onRetry: nil)
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
