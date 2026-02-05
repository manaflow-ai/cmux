import SwiftUI
import WebKit
import AppKit

/// View for rendering a browser panel with address bar
struct BrowserPanelView: View {
    @ObservedObject var panel: BrowserPanel
    let isFocused: Bool
    @State private var addressBarText: String = ""
    @FocusState private var addressBarFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            // Address bar
            HStack(spacing: 8) {
                // Back button
                Button(action: { panel.goBack() }) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.plain)
                .disabled(!panel.canGoBack)
                .opacity(panel.canGoBack ? 1.0 : 0.4)
                .help("Go Back")

                // Forward button
                Button(action: { panel.goForward() }) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.plain)
                .disabled(!panel.canGoForward)
                .opacity(panel.canGoForward ? 1.0 : 0.4)
                .help("Go Forward")

                // Reload/Stop button
                Button(action: {
                    if panel.isLoading {
                        panel.stopLoading()
                    } else {
                        panel.reload()
                    }
                }) {
                    Image(systemName: panel.isLoading ? "xmark" : "arrow.clockwise")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.plain)
                .help(panel.isLoading ? "Stop" : "Reload")

                // URL TextField
                HStack(spacing: 4) {
                    if panel.currentURL?.scheme == "https" {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }

                    TextField("Search or enter URL", text: $addressBarText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .focused($addressBarFocused)
                        .onSubmit {
                            panel.navigateSmart(addressBarText)
                            addressBarFocused = false
                        }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color(nsColor: .textBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(addressBarFocused ? Color.accentColor : Color.clear, lineWidth: 1)
                )
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(Color(nsColor: .windowBackgroundColor))

            // Progress bar
            if panel.isLoading {
                GeometryReader { geo in
                    Rectangle()
                        .fill(Color.accentColor)
                        .frame(width: geo.size.width * panel.estimatedProgress)
                }
                .frame(height: 2)
            }

            // Web view
            WebViewRepresentable(panel: panel, isFocused: isFocused)
                .contextMenu {
                    Button("Open Developer Tools") {
                        openDevTools()
                    }
                    .keyboardShortcut("i", modifiers: [.command, .option])
                }
        }
        .onAppear {
            updateAddressBarText()
        }
        .onChange(of: panel.currentURL) { _ in
            updateAddressBarText()
        }
    }

    private func updateAddressBarText() {
        addressBarText = panel.currentURL?.absoluteString ?? ""
    }

    private func openDevTools() {
        // WKWebView with developerExtrasEnabled allows right-click > Inspect Element
        // We can also trigger via JavaScript
        Task {
            try? await panel.evaluateJavaScript("window.webkit?.messageHandlers?.devTools?.postMessage('open')")
        }
    }
}

/// NSViewRepresentable wrapper for WKWebView
struct WebViewRepresentable: NSViewRepresentable {
    let panel: BrowserPanel
    let isFocused: Bool

    func makeNSView(context: Context) -> WKWebView {
        return panel.webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        // Focus handling
        if isFocused && nsView.window != nil {
            nsView.window?.makeFirstResponder(nsView)
        }
    }
}
