import AppKit
import CEFWebView
import SwiftUI

/// Debug-only window hosting a CEFWebView (Chromium) so we can dogfood the
/// engine before plumbing it into BrowserPanel. Open via Debug > Debug Windows >
/// Chromium (CEF)…
@MainActor
final class CefDebugWindowController: NSWindowController, NSWindowDelegate {
    static let shared = CefDebugWindowController()

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1024, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Chromium (CEF)"
        window.identifier = NSUserInterfaceItemIdentifier("cmux.cefDebug")
        window.isReleasedWhenClosed = false
        window.center()
        window.contentView = NSHostingView(rootView: CefDebugView())
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        window?.makeKeyAndOrderFront(nil)
    }
}

private struct CefDebugView: View {
    @State private var url: URL? = URL(string: "https://www.google.com")
    @State private var urlText: String = "https://www.google.com"
    @State private var state = CEFWebViewState()

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Button {
                    state.goBack()
                } label: {
                    Image(systemName: "chevron.left")
                }
                .disabled(!state.canGoBack)

                Button {
                    state.goForward()
                } label: {
                    Image(systemName: "chevron.right")
                }
                .disabled(!state.canGoForward)

                Button {
                    state.reload()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }

                TextField("URL", text: $urlText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        if let parsed = parseURL(urlText) {
                            url = parsed
                        }
                    }
            }
            .padding(8)

            Divider()

            ZStack {
                CEFWebView(url: $url, state: $state)

                if let err = state.initializationError {
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.largeTitle)
                            .foregroundStyle(.yellow)
                        Text("CEF initialization failed")
                            .font(.headline)
                        ScrollView {
                            Text(err)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .padding()
                        }
                    }
                    .padding()
                    .background(.regularMaterial)
                }
            }

            HStack {
                if state.isLoading {
                    ProgressView().controlSize(.small)
                }
                Text(state.title ?? state.currentURL?.absoluteString ?? "")
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                if state.rendererHelperFailed {
                    Text(state.rendererFailureStatusLine)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
        }
    }

    private func parseURL(_ text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.contains("://") {
            return URL(string: trimmed)
        }
        return URL(string: "https://\(trimmed)")
    }
}
