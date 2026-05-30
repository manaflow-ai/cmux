import AppKit
import WebKit

@MainActor
final class AgentSessionWebHostView: NSView {
    var onDidMoveToWindow: (() -> Void)?
    var onGeometryChanged: (() -> Void)?
    private(set) var geometryRevision: UInt64 = 0
    private var lastReportedGeometryState: GeometryState?
    private var hasPendingGeometryNotification = false
    private weak var hostedWebView: WKWebView?

    private struct GeometryState: Equatable {
        let frame: CGRect
        let bounds: CGRect
        let windowNumber: Int?
        let superviewID: ObjectIdentifier?
    }

    override var isOpaque: Bool { false }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onDidMoveToWindow?()
        notifyGeometryChangedIfNeeded()
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        notifyGeometryChangedIfNeeded()
    }

    override func layout() {
        super.layout()
        if let hostedWebView, hostedWebView.superview === self {
            hostedWebView.frame = bounds
        }
        notifyGeometryChangedIfNeeded()
    }

    override func setFrameOrigin(_ newOrigin: NSPoint) {
        super.setFrameOrigin(newOrigin)
        markGeometryDirtyIfNeeded()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        markGeometryDirtyIfNeeded()
    }

    private func currentGeometryState() -> GeometryState {
        GeometryState(
            frame: frame,
            bounds: bounds,
            windowNumber: window?.windowNumber,
            superviewID: superview.map(ObjectIdentifier.init)
        )
    }

    private func markGeometryDirtyIfNeeded() {
        let state = currentGeometryState()
        guard state != lastReportedGeometryState else { return }
        guard !hasPendingGeometryNotification else { return }
        hasPendingGeometryNotification = true
        Task { @MainActor [weak self] in
            self?.notifyGeometryChangedIfNeeded()
        }
    }

    private func notifyGeometryChangedIfNeeded() {
        hasPendingGeometryNotification = false
        let state = currentGeometryState()
        guard state != lastReportedGeometryState else { return }
        lastReportedGeometryState = state
        geometryRevision &+= 1
        onGeometryChanged?()
    }

    func attachWebView(_ webView: WKWebView) {
        if webView.superview !== self {
            webView.removeFromSuperview()
            addSubview(webView, positioned: .above, relativeTo: nil)
        }
        hostedWebView = webView
        webView.translatesAutoresizingMaskIntoConstraints = true
        webView.autoresizingMask = [.width, .height]
        webView.frame = bounds
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    func detachHostedWebViewIfOwned(_ webView: WKWebView?) {
        guard let webView,
              webView.superview === self else {
            return
        }
        webView.removeFromSuperview()
        if hostedWebView === webView {
            hostedWebView = nil
        }
    }
}

@MainActor
final class AgentSessionWebView: WKWebView {
    var onPointerDown: (() -> Void)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        PaneFirstClickFocusSettings.isEnabled()
    }

    override func mouseDown(with event: NSEvent) {
        onPointerDown?()
        super.mouseDown(with: event)
    }
}
