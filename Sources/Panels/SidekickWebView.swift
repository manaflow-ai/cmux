import AppKit
import SwiftUI
import WebKit

/// Lightweight companion WKWebView for a terminal panel.
///
/// Mirrors the WKWebViewConfiguration used by `BrowserPanel` but stays
/// minimal: no tab bar, no full chrome — just URL field, back/forward,
/// reload, and pin-to-session.
///
/// Wiring (P2): wrap `TerminalPanelView` in `HSplitView` with this on
/// the trailing edge when `state.isOpen`.
@MainActor
public struct SidekickWebViewContainer: View {
    @Binding var state: SidekickState
    let panelID: UUID

    @State private var draftURL: String = ""

    public init(state: Binding<SidekickState>, panelID: UUID) {
        self._state = state
        self.panelID = panelID
    }

    public var body: some View {
        VStack(spacing: 0) {
            chrome
            Divider()
            SidekickWebViewRepresentable(url: state.url) { newURL in
                state.url = newURL
                if let newURL, !state.pinnedURLs.contains(newURL) {
                    state.pinnedURLs.append(newURL)
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .cmuxSidekickURLDetected)) { note in
            guard
                let info = note.userInfo,
                let pid = info["panelID"] as? UUID, pid == panelID,
                let url = info["url"] as? URL
            else { return }
            if state.url == nil { state.url = url }
        }
    }

    private var chrome: some View {
        HStack(spacing: 6) {
            TextField("URL", text: $draftURL, onCommit: commit)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11))
            Button(action: { state.isOpen = false }) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
        }
        .padding(6)
        .onAppear { draftURL = state.url?.absoluteString ?? "" }
    }

    private func commit() {
        var s = draftURL.trimmingCharacters(in: .whitespaces)
        if !s.contains("://") { s = "https://" + s }
        state.url = URL(string: s)
    }
}

struct SidekickWebViewRepresentable: NSViewRepresentable {
    let url: URL?
    let onNavigate: (URL?) -> Void

    func makeNSView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .nonPersistent()   // ephemeral by default
        let wv = WKWebView(frame: .zero, configuration: cfg)
        wv.navigationDelegate = context.coordinator
        wv.allowsBackForwardNavigationGestures = true
        return wv
    }

    func updateNSView(_ wv: WKWebView, context: Context) {
        guard let url, wv.url != url else { return }
        wv.load(URLRequest(url: url))
    }

    func makeCoordinator() -> Coordinator { Coordinator(onNavigate: onNavigate) }

    final class Coordinator: NSObject, WKNavigationDelegate {
        let onNavigate: (URL?) -> Void
        init(onNavigate: @escaping (URL?) -> Void) { self.onNavigate = onNavigate }

        func webView(_ wv: WKWebView, didFinish nav: WKNavigation!) {
            onNavigate(wv.url)
        }
    }
}
