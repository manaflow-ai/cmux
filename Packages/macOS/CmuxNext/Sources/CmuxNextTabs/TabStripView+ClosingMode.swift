import AppKit
import CmuxNextDesign

// Chrome's mouse closing mode exit (tab_container_impl.cc L1418-1474, mouse_watcher.cc L26): after a
// mouse close the tabs keep their widths until the pointer has left the strip extended by
// `closingModeBelowPad` below and `closingModeTrailingPad` past its trailing edge, then
// `closingModeExitDelay` passes (a return cancels it), or the mouse is pressed outside the strip. Then
// the tabs resize on the close tween.
extension TabStripView {
    /// The strip with Chrome's exit margins, in strip coordinates (flipped: y grows down).
    var closingModeArea: CGRect {
        let g = metrics.chrome
        return CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width + g.closingModeTrailingPad,
                      height: bounds.height + g.closingModeBelowPad)
    }

    /// The pointer left the strip in closing mode: follow it until it leaves the extended area.
    func closingModePointerLeft() {
        if closingExitMonitor == nil {
            closingExitMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown, .rightMouseDown]) { [weak self] event in
                self?.closingModePointerEvent(event)
                return event
            }
        }
        closingModePointerMoved(to: window.map { convert($0.mouseLocationOutsideOfEventStream, from: nil) })
    }

    private func closingModePointerEvent(_ event: NSEvent) {
        guard event.window === window else {
            if event.type != .mouseMoved { exitClosingMode() }
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        if event.type != .mouseMoved, !bounds.contains(point) {
            exitClosingMode()
        } else {
            closingModePointerMoved(to: point)
        }
    }

    private func closingModePointerMoved(to point: CGPoint?) {
        guard closingModeWidth != nil, drag == nil else { return endClosingModeWatch() }
        if let point, closingModeArea.contains(point) {
            closingExit.cancel()
        } else {
            let delay = metrics.chrome.closingModeExitDelay
            closingExit.scheduleIfIdle(after: .milliseconds(Int((delay * 1000).rounded()))) { @MainActor [weak self] in
                self?.exitClosingMode()
            }
        }
    }

    /// The pointer came back into the strip: closing mode stays.
    func closingModePointerReturned() {
        closingExit.cancel()
    }

    /// Ends closing mode: the tabs resize to the full strip on the close tween.
    func exitClosingMode() {
        endClosingModeWatch()
        guard closingModeWidth != nil else { return }
        closingModeWidth = nil
        relayout(animated: !reduceMotion, token: .tabClose)
    }

    func endClosingModeWatch() {
        closingExit.cancel()
        if let closingExitMonitor { NSEvent.removeMonitor(closingExitMonitor) }
        closingExitMonitor = nil
    }
}
