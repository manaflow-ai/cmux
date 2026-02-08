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
                        .onExitCommand {
                            // Escape should leave the omnibar and return focus to the web view.
                            guard addressBarFocused else { return }
                            addressBarFocused = false
                            DispatchQueue.main.async {
                                guard isFocused else { return }
                                guard let window = panel.webView.window,
                                      !panel.webView.isHiddenOrHasHiddenAncestor else { return }
                                window.makeFirstResponder(panel.webView)
                                NotificationCenter.default.post(name: .browserDidExitAddressBar, object: panel.id)
                            }
                        }
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
            // If the browser surface is focused but has no URL loaded yet, auto-focus the omnibar.
            autoFocusOmnibarIfBlank()
        }
        .onChange(of: panel.currentURL) { _ in
            let addressWasEmpty = addressBarText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            updateAddressBarText()
            // If we auto-focused a blank omnibar but then a URL loads programmatically, move focus
            // into WebKit unless the user had already started typing.
            if addressBarFocused, addressWasEmpty, !isWebViewBlank() {
                addressBarFocused = false
            }
        }
        .onChange(of: isFocused) { focused in
            // Ensure this view doesn't retain focus while hidden (bonsplit keepAllAlive).
            if focused {
                autoFocusOmnibarIfBlank()
            } else {
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

    /// Treat a WebView with no URL (or about:blank) as "blank" for UX purposes.
    private func isWebViewBlank() -> Bool {
        guard let url = panel.webView.url else { return true }
        return url.absoluteString == "about:blank"
    }

    private func autoFocusOmnibarIfBlank() {
        guard isFocused else { return }
        guard !addressBarFocused else { return }
        // If a real navigation is underway (e.g. open_browser https://...), don't steal focus.
        guard !panel.webView.isLoading else { return }
        guard isWebViewBlank() else { return }
        addressBarFocused = true
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
        var attachRetryWorkItem: DispatchWorkItem?
        var attachRetryCount: Int = 0
        var attachGeneration: Int = 0
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        return container
    }

    private static func attachWebView(_ webView: WKWebView, to host: NSView, coordinator: Coordinator) {
        // Detach from any previous host (bonsplit/SwiftUI may rearrange views).
        webView.removeFromSuperview()
        host.subviews.forEach { $0.removeFromSuperview() }
        host.addSubview(webView)

        webView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.deactivate(coordinator.constraints)
        coordinator.constraints = [
            webView.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            webView.topAnchor.constraint(equalTo: host.topAnchor),
            webView.bottomAnchor.constraint(equalTo: host.bottomAnchor),
        ]
        NSLayoutConstraint.activate(coordinator.constraints)

        // Make reparenting resilient: WebKit can occasionally stay visually blank until forced to lay out.
        webView.needsLayout = true
        webView.layoutSubtreeIfNeeded()
        webView.needsDisplay = true
        webView.displayIfNeeded()
    }

    private static func scheduleAttachRetry(_ webView: WKWebView, to host: NSView, coordinator: Coordinator, generation: Int) {
        // Don't schedule multiple overlapping retries.
        guard coordinator.attachRetryWorkItem == nil else { return }

        let work = DispatchWorkItem { [weak host, weak webView] in
            coordinator.attachRetryWorkItem = nil
            guard let host, let webView else { return }
            guard coordinator.attachGeneration == generation else { return }

            // If already attached, we're done.
            if webView.superview === host {
                coordinator.attachRetryCount = 0
                return
            }

            // Wait until the host is actually in a window. SwiftUI can create a new container before it
            // is in a window during bonsplit tree updates; moving the webview too early can be flaky.
            guard host.window != nil else {
                coordinator.attachRetryCount += 1
                // Be generous here: bonsplit structural updates can keep a representable
                // container off-window longer than a few seconds under load.
                if coordinator.attachRetryCount < 400 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        scheduleAttachRetry(webView, to: host, coordinator: coordinator, generation: generation)
                    }
                }
                return
            }

            coordinator.attachRetryCount = 0
            attachWebView(webView, to: host, coordinator: coordinator)
        }

        coordinator.attachRetryWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: work)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        let webView = panel.webView
        context.coordinator.webView = webView

        if webView.superview !== nsView {
            // Cancel any pending retry; we'll reschedule if needed.
            context.coordinator.attachRetryWorkItem?.cancel()
            context.coordinator.attachRetryWorkItem = nil
            context.coordinator.attachGeneration += 1

            if nsView.window == nil {
                // Avoid attaching to off-window containers; during bonsplit structural updates SwiftUI
                // can create containers that are never inserted into the window.
                Self.scheduleAttachRetry(
                    webView,
                    to: nsView,
                    coordinator: context.coordinator,
                    generation: context.coordinator.attachGeneration
                )
            } else {
                Self.attachWebView(webView, to: nsView, coordinator: context.coordinator)
            }
        } else {
            // Already attached; no need for any pending retry.
            context.coordinator.attachRetryWorkItem?.cancel()
            context.coordinator.attachRetryWorkItem = nil
            context.coordinator.attachRetryCount = 0
            context.coordinator.attachGeneration += 1
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
        coordinator.attachRetryWorkItem?.cancel()
        coordinator.attachRetryWorkItem = nil
        coordinator.attachRetryCount = 0
        coordinator.attachGeneration += 1

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
