import AppKit
import SwiftUI

struct ApplicationCaptureRepresentable: NSViewRepresentable {
    let panel: ApplicationPanel
    let windowID: CGWindowID
    let isVisibleInUI: Bool

    func makeNSView(context: Context) -> ApplicationCaptureView {
        let captureToken = panel.beginCaptureSession()
        let view = ApplicationCaptureView(
            windowID: windowID,
            processID: panel.processID,
            targetFrameRate: panel.targetFrameRate,
            onStateChanged: { [weak panel] state in
                panel?.updateCaptureState(state, token: captureToken)
            },
            onMovedToWindow: { [weak panel] view in
                panel?.captureViewDidMoveToWindow(view, token: captureToken)
            }
        )
        panel.attach(view, token: captureToken)
        view.setCaptureActive(isVisibleInUI)
        return view
    }

    func updateNSView(_ nsView: ApplicationCaptureView, context: Context) {
        nsView.setCaptureActive(isVisibleInUI)
    }

    static func dismantleNSView(_ nsView: ApplicationCaptureView, coordinator: ()) {
        nsView.stopCapture()
    }
}
