import AppKit
import SwiftUI

/// Native UI in the browser content area. A hidden WebKit portal cannot cover
/// the connection panel because the web view only mounts after a page loads.
struct CloudBrowserAccessView<Content: View>: View {
    let panel: BrowserPanel
    let backgroundColor: NSColor
    @ViewBuilder let content: () -> Content
    @State private var showsVPNSetup = false

    var body: some View {
        let state = panel.cloudAccess
        Group {
            if let model = state.model {
                VStack(spacing: 0) {
                    HStack(spacing: 10) {
                        Label(CloudPortAccessText.status(model.phase), systemImage: "network")
                        Spacer(minLength: 0)
                        Button(String(localized: "cloud.vpn.setup.title", defaultValue: "Cloud VPN")) {
                            showsVPNSetup.toggle()
                        }
                        Button(String(localized: "cloud.ports.title", defaultValue: "Ports")) { state.showsPorts.toggle() }
                            .accessibilityIdentifier("CloudBrowserPortsButton")
                    }
                    .font(.system(size: 12))
                    .padding(10)
                    if state.showsPorts || model.prefersForwarding {
                        ScrollView(.horizontal) {
                            CloudPortsTable(models: [model], allowsStart: state.remoteURL?.scheme == "http")
                        }
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    if showsVPNSetup {
                        CloudVPNSetupPanelView(
                            appearance: PanelAppearance(backgroundColor: backgroundColor, foregroundColor: .labelColor, dividerColor: .secondary, unfocusedOverlayNSColor: .clear, unfocusedOverlayOpacity: 0, usesClearContentBackground: false),
                            onRequestPanelFocus: {},
                            model: model.vpn
                        )
                    } else if state.showsPage {
                        content()
                    } else {
                        CloudBrowserConnectionCard(
                            address: state.remoteURL?.absoluteString ?? "",
                            phase: model.phase,
                            message: state.error ?? model.failureMessage ?? model.vpn.unavailableMessage,
                            onSetup: { showsVPNSetup = true },
                            onRetry: {
                                state.retry()
                                navigateIfReady()
                            }
                        )
                    }
                }
                .task(id: model.phase) {
                    if model.isReady { showsVPNSetup = false }
                    navigateIfReady()
                }
                .task(id: state.remoteURL) { navigateIfReady() }
            } else if let message = state.unavailable {
                CloudBrowserConnectionCard(address: "", phase: .failed(message), message: message, onSetup: {}, onRetry: {})
            } else {
                content()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: backgroundColor))
        .accessibilityIdentifier("CloudBrowserAccess")
    }

    private func navigateIfReady() {
        guard let url = panel.cloudAccess.nextURL() else {
            if panel.cloudAccess.model?.isReady != true { panel.webView.stopLoading() }
            return
        }
        _ = panel.navigate(to: url)
    }
}
