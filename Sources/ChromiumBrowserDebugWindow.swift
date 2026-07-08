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
    // The Chromium runtime cannot be unloaded; keep one instance for the process.
    private var runtime: ChromiumRuntime?

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
            let bundle = try ChromiumRuntimeLocator().locate()
            let runtime = self.runtime ?? ChromiumRuntime(bundle: bundle)
            self.runtime = runtime
            try await runtime.start()
            let session = try await runtime.openSession(
                initialURL: Self.defaultURL,
                userDataDirectory: profileDirectory(),
                enableDevTools: true
            )
            let model = ChromiumBrowserModel()
            let webView = ChromiumWebView(session: session, model: model)
            phase = .running(session: session, model: model, webView: webView)
        } catch {
            phase = .failed(message: error.localizedDescription)
        }
    }

    private func profileDirectory() -> URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let directory = base.appendingPathComponent("cmux/chromium-debug-profile", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
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
                try? await session.openDevTools(mode: .bottom)
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
