import AppKit
import WebKit

@MainActor
final class AgentSessionWebView: WKWebView {
    var onPointerDown: (() -> Void)?
    private var mouseDownMonitor: Any?

    deinit {
        MainActor.assumeIsolated {
            removeEventMonitors()
        }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        PaneFirstClickFocusSettings.isEnabled()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            removeEventMonitors()
        } else {
            installEventMonitors()
        }
    }

    override func mouseDown(with event: NSEvent) {
        onPointerDown?()
        _ = window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        submitComposerPointerDownIfNeeded(at: point, source: "mouseDown")
        super.mouseDown(with: event)
    }

    func focusComposer() {
        evaluateJavaScript("window.cmuxAgentBridge?.focusComposer?.();") { _, error in
#if DEBUG
            if let error {
                cmuxDebugLog("agentSession.web.focusComposer error=\(error.localizedDescription)")
            } else {
                cmuxDebugLog("agentSession.web.focusComposer")
            }
#endif
        }
    }

    private func installEventMonitors() {
        if mouseDownMonitor == nil {
            mouseDownMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] event in
                guard let self,
                      event.window === self.window else {
                    return event
                }
                let point = self.convert(event.locationInWindow, from: nil)
                guard self.bounds.contains(point) else {
                    return event
                }
                self.onPointerDown?()
                _ = self.window?.makeFirstResponder(self)
                self.submitComposerPointerDownIfNeeded(at: point, source: "localMouseMonitor")
                return event
            }
        }
    }

    private func removeEventMonitors() {
        if let mouseDownMonitor {
            NSEvent.removeMonitor(mouseDownMonitor)
            self.mouseDownMonitor = nil
        }
    }

    private func submitComposerPointerDownIfNeeded(at point: NSPoint, source: String) {
        let clientPoint = Self.clientCoordinatesForNativePointerDown(at: point)
        let x = clientPoint.x
        let y = clientPoint.y
        evaluateJavaScript("window.cmuxAgentBridge?.pointerDownAt?.(\(x), \(y));") { result, error in
#if DEBUG
            let handled = (result as? Bool).map { $0 ? 1 : 0 } ?? -1
            if let error {
                cmuxDebugLog(
                    "agentSession.web.pointerDown source=\(source) " +
                    "x=\(String(format: "%.1f", x)) y=\(String(format: "%.1f", y)) " +
                    "handled=\(handled) error=\(error.localizedDescription)"
                )
            } else {
                cmuxDebugLog(
                    "agentSession.web.pointerDown source=\(source) " +
                    "x=\(String(format: "%.1f", x)) y=\(String(format: "%.1f", y)) " +
                    "handled=\(handled)"
                )
            }
#endif
        }
    }

    nonisolated static func clientCoordinatesForNativePointerDown(at point: NSPoint) -> (x: Double, y: Double) {
        (Double(point.x), Double(point.y))
    }
}
