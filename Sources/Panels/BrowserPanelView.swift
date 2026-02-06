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
            WebViewRepresentable(panel: panel, shouldFocusWebView: isFocused && !addressBarFocused)
                .contextMenu {
                    Button("Open Developer Tools") {
                        openDevTools()
                    }
                    .keyboardShortcut("i", modifiers: [.command, .option])
                }
        }
        .onAppear {
            updateAddressBarText()
            // Auto-focus address bar when browser is first created (blank URL)
            if panel.currentURL == nil {
                addressBarFocused = true
            }
        }
        .onChange(of: panel.currentURL) { _ in
            updateAddressBarText()
        }
        .onChange(of: isFocused) { focused in
            // Ensure this view doesn't retain focus while hidden (bonsplit keepAllAlive).
            if !focused {
                addressBarFocused = false
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .browserFocusAddressBar)) { notification in
            guard let panelId = notification.object as? UUID, panelId == panel.id else { return }
            addressBarFocused = true
            // Select all text for easy replacement
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
            }
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
    let shouldFocusWebView: Bool

    final class Coordinator {
        weak var webView: WKWebView?
        var constraints: [NSLayoutConstraint] = []
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        let webView = panel.webView
        context.coordinator.webView = webView

        if webView.superview !== nsView {
            // Don't steal the WKWebView into an off-window host. During bonsplit tree updates SwiftUI can
            // create a new container before it is in a window; moving the webview too early can be flaky.
            if webView.superview != nil && nsView.window == nil {
                // Wait until this host is actually in a window.
            } else {
                // Detach from any previous host (bonsplit/SwiftUI may rearrange views).
                webView.removeFromSuperview()
                nsView.subviews.forEach { $0.removeFromSuperview() }
                nsView.addSubview(webView)

                webView.translatesAutoresizingMaskIntoConstraints = false
                NSLayoutConstraint.deactivate(context.coordinator.constraints)
                context.coordinator.constraints = [
                    webView.leadingAnchor.constraint(equalTo: nsView.leadingAnchor),
                    webView.trailingAnchor.constraint(equalTo: nsView.trailingAnchor),
                    webView.topAnchor.constraint(equalTo: nsView.topAnchor),
                    webView.bottomAnchor.constraint(equalTo: nsView.bottomAnchor),
                ]
                NSLayoutConstraint.activate(context.coordinator.constraints)
            }
        }

        // Focus handling. Avoid fighting the address bar when it is focused.
        guard let window = nsView.window else { return }
        if shouldFocusWebView {
            if let fr = window.firstResponder as? NSView, fr.isDescendant(of: webView) {
                return
            }
            window.makeFirstResponder(webView)
        } else {
            if let fr = window.firstResponder as? NSView, fr.isDescendant(of: webView) {
                window.makeFirstResponder(nil)
            }
        }
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        NSLayoutConstraint.deactivate(coordinator.constraints)
        coordinator.constraints.removeAll()

        guard let webView = coordinator.webView else { return }

        // If we're being torn down while the WKWebView (or one of its subviews) is first responder,
        // resign it before detaching.
        if let window = nsView.window, let fr = window.firstResponder as? NSView, fr.isDescendant(of: webView) {
            window.makeFirstResponder(nil)
        }
        if webView.superview === nsView {
            webView.removeFromSuperview()
        }
    }
}
