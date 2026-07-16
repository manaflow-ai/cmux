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
    private var sessionContentWidthPresentation = SessionContentWidthPresentation.disabled

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
            hostedWebView.frame = sessionContentWidthPresentation.contentFrame(in: bounds)
        }
        notifyGeometryChangedIfNeeded()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        hostedWebView?.acceptsFirstMouse(for: event) ?? false
    }

    override func mouseDown(with event: NSEvent) {
        guard let webView = hostedWebView as? AgentSessionWebView else { return }
        webView.onPointerDown?()
        window?.makeFirstResponder(webView)
    }

    override func scrollWheel(with event: NSEvent) {
        guard let hostedWebView else { return }
        guard let cgEvent = event.cgEvent?.copy() else {
            hostedWebView.scrollWheel(with: event)
            return
        }

        let targetInWindow = hostedWebView.convert(
            NSPoint(x: hostedWebView.bounds.midX, y: hostedWebView.bounds.midY),
            to: nil
        )
        let windowDelta = NSPoint(
            x: targetInWindow.x - event.locationInWindow.x,
            y: targetInWindow.y - event.locationInWindow.y
        )
        var targetInQuartz = cgEvent.location
        targetInQuartz.x += windowDelta.x
        targetInQuartz.y -= windowDelta.y
        cgEvent.location = targetInQuartz

        guard let retargetedEvent = NSEvent(cgEvent: cgEvent) else {
            hostedWebView.scrollWheel(with: event)
            return
        }
        hostedWebView.scrollWheel(with: retargetedEvent)
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
        webView.autoresizingMask = []
        webView.frame = sessionContentWidthPresentation.contentFrame(in: bounds)
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    func setSessionContentWidthPresentation(_ presentation: SessionContentWidthPresentation) {
        guard sessionContentWidthPresentation != presentation else { return }
        sessionContentWidthPresentation = presentation
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
