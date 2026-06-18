import AppKit
import WebKit

@MainActor
final class AgentSessionWebHostView: NSView {
    var onDidMoveToWindow: (() -> Void)?
    var onGeometryChanged: (() -> Void)?
    private(set) var geometryRevision: UInt64 = 0
    private var lastReportedAgentSessionWebHostGeometryState: AgentSessionWebHostGeometryState?
    private var hasPendingGeometryNotification = false
    private weak var hostedWebView: WKWebView?

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

    private func currentAgentSessionWebHostGeometryState() -> AgentSessionWebHostGeometryState {
        AgentSessionWebHostGeometryState(
            frame: frame,
            bounds: bounds,
            windowNumber: window?.windowNumber,
            superviewID: superview.map(ObjectIdentifier.init)
        )
    }

    private func markGeometryDirtyIfNeeded() {
        let state = currentAgentSessionWebHostGeometryState()
        guard state != lastReportedAgentSessionWebHostGeometryState else { return }
        guard !hasPendingGeometryNotification else { return }
        hasPendingGeometryNotification = true
        Task { @MainActor [weak self] in
            self?.notifyGeometryChangedIfNeeded()
        }
    }

    private func notifyGeometryChangedIfNeeded() {
        hasPendingGeometryNotification = false
        let state = currentAgentSessionWebHostGeometryState()
        guard state != lastReportedAgentSessionWebHostGeometryState else { return }
        lastReportedAgentSessionWebHostGeometryState = state
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
