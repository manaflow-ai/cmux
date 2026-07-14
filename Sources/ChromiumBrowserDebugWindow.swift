import AppKit
import CmuxChromium
import Foundation
import SwiftUI

/// Owns the experimental Chromium runtime/session lifecycle for the debug window.
@MainActor
@Observable
final class ChromiumBrowserDebugSessionController {
    enum Phase {
        case idle
        case starting
        case running(session: ChromiumSession, model: ChromiumBrowserModel, webView: ChromiumWebView)
        case failed(message: String)
    }

    static let defaultURL = "https://www.google.com"

    private(set) var phase: Phase = .idle

    func startIfNeeded() {
        switch phase {
        case .idle, .failed:
            break
        case .starting, .running:
            return
        }
        phase = .starting
        Task {
            await start()
        }
    }

    func closeSession() {
        if case .running(let session, _, _) = phase {
            session.close()
        }
        phase = .idle
    }

    private func start() async {
        do {
            let (session, model, webView) = try await ChromiumRuntimeManager.shared.acquireSession(
                initialURL: Self.defaultURL,
                profileID: UUID()
            )
            phase = .running(session: session, model: model, webView: webView)
        } catch {
            phase = .failed(message: error.localizedDescription)
        }
    }
}

final class ChromiumBrowserDebugWindowController: ReleasingWindowController {
    static let shared = ChromiumBrowserDebugWindowController()

    private let sessionController = ChromiumBrowserDebugSessionController()

    override func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1080, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = String(
            localized: "chromiumDebug.window.title",
            defaultValue: "Chromium Browser (Experimental)"
        )
        window.identifier = NSUserInterfaceItemIdentifier("cmux.chromiumBrowserDebug")
        window.center()
        window.contentView = NSHostingView(rootView: ChromiumBrowserDebugView(controller: sessionController))
        AppDelegate.shared?.applyWindowDecorations(to: window)
        return window
    }

    override func managedWindowWillClose(_ window: NSWindow) {
        sessionController.closeSession()
    }

    func show() {
        showManagedWindow()
    }
}

private struct ChromiumBrowserDebugView: View {
    let controller: ChromiumBrowserDebugSessionController

    var body: some View {
        content
            .onAppear {
                controller.startIfNeeded()
            }
    }

    @ViewBuilder
    private var content: some View {
        switch controller.phase {
        case .idle, .starting:
            VStack(spacing: 12) {
                ProgressView()
                Text(String(localized: "chromiumDebug.starting", defaultValue: "Starting Chromium…"))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 32))
                    .foregroundStyle(.secondary)
                Text(String(
                    localized: "chromiumDebug.failedTitle",
                    defaultValue: "Chromium Runtime Unavailable"
                ))
                .font(.headline)
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Text(String(
                    localized: "chromiumDebug.instructions",
                    defaultValue: "Install a runtime with scripts/fetch-chromium-runtime.sh, or point CMUX_CHROMIUM_RUNTIME_DIR at an extracted runtime, then retry."
                ))
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                Button(String(localized: "chromiumDebug.retry", defaultValue: "Retry")) {
                    controller.startIfNeeded()
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .running(let session, let model, let webView):
            ChromiumBrowserContentView(session: session, model: model, webView: webView)
        }
    }
}

private struct ChromiumBrowserContentView: View {
    let session: ChromiumSession
    let model: ChromiumBrowserModel
    let webView: ChromiumWebView

    @State private var urlText = ""
    @State private var isDevToolsOpen = false

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if model.isDisconnected {
                Text(String(
                    localized: "chromiumDebug.disconnected",
                    defaultValue: "The browser process disconnected."
                ))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ChromiumWebViewRepresentable(webView: webView)
            }
        }
        .onAppear {
            urlText = model.currentURL
        }
        .onChange(of: model.currentURL) { _, newValue in
            urlText = newValue
        }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Button {
                runJavaScript("history.back()")
            } label: {
                Image(systemName: "chevron.left")
            }
            .help(String(localized: "chromiumDebug.back", defaultValue: "Back"))

            Button {
                runJavaScript("history.forward()")
            } label: {
                Image(systemName: "chevron.right")
            }
            .help(String(localized: "chromiumDebug.forward", defaultValue: "Forward"))

            Button {
                runJavaScript("location.reload()")
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help(String(localized: "chromiumDebug.reload", defaultValue: "Reload"))

            TextField(
                String(localized: "chromiumDebug.urlPlaceholder", defaultValue: "Enter URL"),
                text: $urlText
            )
            .textFieldStyle(.roundedBorder)
            .autocorrectionDisabled()
            .onSubmit {
                navigate(to: urlText)
            }

            if model.isLoading {
                ProgressView()
                    .controlSize(.small)
            }

            Button {
                toggleDevTools()
            } label: {
                Image(systemName: "wrench.and.screwdriver")
            }
            .help(String(localized: "chromiumDebug.devtools", defaultValue: "DevTools"))
        }
        .buttonStyle(.borderless)
        .padding(8)
    }

    private func navigate(to input: String) {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let url = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        Task {
            try? await session.navigate(to: url)
        }
    }

    private func runJavaScript(_ script: String) {
        Task {
            _ = try? await session.executeJavaScript(script)
        }
    }

    private func toggleDevTools() {
        let opening = !isDevToolsOpen
        isDevToolsOpen = opening
        Task {
            if opening {
                // Docked DevTools is a separate shell surface cmux never composites;
                // open in its own window so the shell presents it. See BrowserPanel.
                try? await session.openDevTools(mode: .window)
            } else {
                try? await session.closeDevTools()
            }
        }
    }
}

private struct ChromiumWebViewRepresentable: NSViewRepresentable {
    let webView: ChromiumWebView

    func makeNSView(context: Context) -> ChromiumWebView {
        webView
    }

    func updateNSView(_ nsView: ChromiumWebView, context: Context) {}
}
