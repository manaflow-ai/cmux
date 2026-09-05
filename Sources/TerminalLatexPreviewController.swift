import AppKit
import CMUXMobileCore
import CmuxTerminal
import GhosttyKit
import WebKit

/// Observes visible agent terminals and paints math in their existing source cells.
@MainActor
final class TerminalLatexPreviewController: NSObject, WKNavigationDelegate {
    private weak var host: GhosttySurfaceScrollView?
    private weak var workspace: Workspace?
    private var workspaceTask: Task<Void, Never>?
    private var frameTask: Task<Void, Never>?
    private var themeTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var releaseFrameDemand: (() -> Void)?
    private var webView: TerminalLatexWebView?
    private var loaded = false
    private var lastText: String?
    private var lastEquations: [TerminalLatexEquation]?
    private var revision: UInt64 = 0
    private var refreshRequested = false
    private var lastCursor = ""

    /// Creates a dormant preview controller for a terminal host.
    init(host: GhosttySurfaceScrollView) {
        self.host = host
        super.init()
    }

    /// Rebinds observers after the host changes workspace, surface, or visibility.
    func rebind() {
        guard let host else { return }
        let nextWorkspace = host.surfaceView.terminalSurface?.owningWorkspace()
        if workspace !== nextWorkspace {
            clear()
            workspaceTask?.cancel()
            workspace = nextWorkspace
            if let nextWorkspace {
                let changes = nextWorkspace.sidebarAgentRuntimeObservation.changes()
                workspaceTask = Task { [weak self] in
                    for await _ in changes {
                        guard !Task.isCancelled else { return }
                        self?.refreshEligibility()
                    }
                }
            }
        }
        refreshEligibility()
    }

    /// Hides stale previews and requests fresh terminal geometry.
    func invalidateGeometry() {
        clear()
        requestRefresh()
    }

    /// Runs preview observers only while a supported agent terminal is visible.
    private func refreshEligibility() {
        guard let host else { return }
        let keys = host.surfaceView.terminalSurface.flatMap { workspace?.agentPIDKeysByPanelId[$0.id] } ?? []
        let isAgent = keys.contains { $0 == "claude_code" || $0 == "codex" || $0.hasPrefix("codex.") }
        let active = isAgent && host.isVisibleInUI && host.window != nil
        if active, releaseFrameDemand == nil {
            releaseFrameDemand = host.surfaceView.retainLocalRenderedFrameNotifications()
            let themes = NotificationCenter.default.notifications(named: .ghosttySurfaceThemeDidChange)
            themeTask = Task { [weak self] in
                for await surfaceID in themes.compactMap({ $0.object as? UUID }) {
                    guard !Task.isCancelled else { return }
                    if self?.host?.surfaceView.terminalSurface?.id == surfaceID {
                        self?.invalidateGeometry()
                    }
                }
            }
            let frames = NotificationCenter.default.notifications(named: .ghosttyDidRenderFrame, object: host.surfaceView)
            frameTask = Task { [weak self] in
                for await _ in frames.map({ _ in () }) {
                    guard !Task.isCancelled else { return }
                    self?.requestRefresh()
                }
            }
            requestRefresh()
        } else if !active {
            frameTask?.cancel()
            frameTask = nil
            themeTask?.cancel()
            themeTask = nil
            refreshTask?.cancel()
            refreshRequested = false
            releaseFrameDemand?()
            releaseFrameDemand = nil
            clear()
        }
    }

    /// Invalidates pending work and hides the current overlay.
    private func clear() {
        revision &+= 1
        lastText = nil
        lastEquations = nil
        webView?.isHidden = true
    }

    /// Coalesces render notifications behind any refresh already in progress.
    private func requestRefresh() {
        guard releaseFrameDemand != nil else { return }
        refreshRequested = true
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                self.refreshRequested = false
                await self.refresh()
                if !self.refreshRequested { break }
            }
            self.refreshTask = nil
            if self.refreshRequested { self.requestRefresh() }
        }
    }

    /// Reads the visible frame and updates its equation overlay.
    private func refresh() async {
        guard let host, host.isVisibleInUI,
              let terminal = host.surfaceView.terminalSurface,
              let surface = terminal.surface else { clear(); return }
        // Selection must remain visible and copy the original terminal source.
        guard !ghostty_surface_has_selection(surface) else { clear(); return }
        guard let text = terminal.readText(region: .viewport) else { clear(); return }
        var metrics = ghostty_surface_grid_metrics_s()
        guard ghostty_surface_grid_metrics(surface, &metrics),
              metrics.cell_width > 0, metrics.cell_height > 0 else { clear(); return }
        let cursor = "\(metrics.cursor_row):\(metrics.cursor_column):\(metrics.cursor_in_viewport)"
        guard text != lastText || cursor != lastCursor else { return }
        lastCursor = cursor
        guard text.contains("$") || text.contains(#"\("#) || text.contains(#"\["#) else {
            clear()
            lastText = text
            return
        }
        guard let snapshot = terminal.mobileRenderGridFrame(stateSeq: 0, includeTheme: false)?.frame else {
            clear()
            return
        }
        let capturedRevision = revision
        let equations = await Task.detached(priority: .utility) {
            TerminalLatexScanner().equations(in: snapshot)
        }.value
        guard !Task.isCancelled, revision == capturedRevision else { return }
        guard !equations.isEmpty else { clear(); lastText = text; return }
        if equations == lastEquations { lastText = text; return }
        guard let webView = ensureWebView(), loaded else { return }
        let data = try? JSONEncoder().encode(equations)
        guard let data, let objects = try? JSONSerialization.jsonObject(with: data) else { return }
        let viewport = host.convert(host.surfaceView.bounds, from: host.surfaceView)
        webView.frame = viewport
        let payload: [String: Any] = [
            "equations": objects,
            "cellWidth": metrics.cell_width,
            "cellHeight": metrics.cell_height,
            "paddingLeft": metrics.padding_left,
            "paddingTop": metrics.padding_top,
            "foreground": snapshot.terminalForeground ?? "#dddddd",
            "background": snapshot.terminalBackground ?? "#1e1e1e",
        ]
        do {
            _ = try await webView.callAsyncJavaScript(
                "window.updateTerminalLatex(preview)", arguments: ["preview": payload],
                in: nil, contentWorld: .page
            )
            guard !Task.isCancelled, revision == capturedRevision else { return }
            webView.isHidden = false
            lastText = text
            lastEquations = equations
        } catch {
            clear()
        }
    }

    /// Creates the isolated renderer the first time a preview is needed.
    private func ensureWebView() -> TerminalLatexWebView? {
        if let webView { return webView }
        guard let host,
              let url = Bundle.main.url(forResource: "terminal-latex", withExtension: "html",
                                        subdirectory: "markdown-viewer/webviews-app") else { return nil }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let view = TerminalLatexWebView(frame: host.bounds, configuration: configuration)
        view.setValue(false, forKey: "drawsBackground")
        view.underPageBackgroundColor = .clear
        view.navigationDelegate = self
        view.isHidden = true
        // The terminal is portal-hosted; keep math above its scroll view and
        // below pane-level find, drop, and inactive overlays.
        let scrollView = host.surfaceView.enclosingScrollView
        host.addSubview(view, positioned: .above, relativeTo: scrollView)
        webView = view
        view.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        return view
    }

    /// Refreshes once the bundled renderer is ready to receive equations.
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loaded = true
        requestRefresh()
    }

    /// Reloads the bundled renderer after a WebKit process termination.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        loaded = false
        clear()
        webView.reload()
    }

    deinit {
        workspaceTask?.cancel()
        frameTask?.cancel()
        themeTask?.cancel()
        refreshTask?.cancel()
        releaseFrameDemand?()
    }
}
