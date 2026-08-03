import AppKit

@MainActor
final class AgentSessionPanelNativeView: NSView {
    private let host = AgentSessionWebHostView()
    private weak var coordinator: AgentSessionWebRendererCoordinator?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        host.translatesAutoresizingMaskIntoConstraints = false
        addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: leadingAnchor),
            host.trailingAnchor.constraint(equalTo: trailingAnchor),
            host.topAnchor.constraint(equalTo: topAnchor),
            host.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(
        panel: AgentSessionPanel,
        isFocused: Bool,
        isVisibleInUI: Bool,
        backgroundColor: NSColor,
        theme: AgentSessionWebTheme,
        sessionContentWidthPresentation: SessionContentWidthPresentation,
        onRequestPanelFocus: @escaping () -> Void
    ) {
        applyBackground(backgroundColor, to: self)
        applyBackground(backgroundColor, to: host)
        host.isHidden = !isVisibleInUI
        guard isVisibleInUI else {
            detachContent()
            return
        }

        let nextCoordinator = panel.rendererSession.coordinator(
            panelId: panel.id,
            workspaceId: panel.workspaceId,
            rendererKind: panel.rendererKind,
            initialProviderID: panel.currentProviderID,
            workingDirectory: panel.workingDirectory,
            theme: theme,
            isFocused: isFocused
        )
        if coordinator !== nextCoordinator {
            detachContent()
            coordinator = nextCoordinator
        }

        let webView = nextCoordinator.ensureWebView(onPointerDown: onRequestPanelFocus)
        webView.onPointerDown = onRequestPanelFocus
        webView.navigationDelegate = nextCoordinator
        webView.uiDelegate = nextCoordinator
        webView.underPageBackgroundColor = backgroundColor
        applyBackground(backgroundColor, to: webView)
        let resolvedAppearance = NSAppearance(named: theme.isDark ? .darkAqua : .aqua)
        if webView.appearance !== resolvedAppearance {
            webView.appearance = resolvedAppearance
        }

        host.setSessionContentWidthPresentation(sessionContentWidthPresentation)
        host.attachWebView(webView)
        host.onDidMoveToWindow = { [weak nextCoordinator] in
            nextCoordinator?.loadShellIfNeeded()
            nextCoordinator?.flushVisiblePaintIfReady()
        }
        host.onGeometryChanged = { [weak nextCoordinator] in
            nextCoordinator?.flushVisiblePaintIfReady()
        }
        nextCoordinator.loadShellIfNeeded()
        nextCoordinator.flushVisiblePaintIfReady()
        if isFocused {
            nextCoordinator.focus()
        }
    }

    func teardown() {
        detachContent()
        coordinator = nil
    }

    private func detachContent() {
        host.detachHostedWebViewIfOwned(coordinator?.webView)
        host.onDidMoveToWindow = nil
        host.onGeometryChanged = nil
    }

    private func applyBackground(_ color: NSColor, to view: NSView) {
        view.wantsLayer = true
        view.layer?.backgroundColor = color.cgColor
        view.layer?.isOpaque = color.alphaComponent >= 0.999
    }
}
