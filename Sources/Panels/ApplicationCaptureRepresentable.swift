import AppKit
import SwiftUI

struct ApplicationCaptureRepresentable: NSViewRepresentable {
    let panel: ApplicationPanel
    let windowID: CGWindowID
    let processID: pid_t
    let isVisibleInUI: Bool

    final class Coordinator {
        weak var panel: ApplicationPanel?
        var captureToken: UUID?
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> ApplicationCaptureView {
        let captureToken = panel.beginCaptureSession()
        context.coordinator.panel = panel
        context.coordinator.captureToken = captureToken
        let view = ApplicationCaptureView(
            windowID: windowID,
            processID: processID,
            targetFrameRate: panel.targetFrameRate,
            runtime: panel.runtime,
            leaseProvider: { [weak panel] in
                await panel?.applicationSurfaceLease()
            },
            onStateChanged: { [weak panel] state in
                panel?.updateCaptureState(state, token: captureToken)
            },
            onMovedToWindow: { [weak panel] view in
                panel?.captureViewDidMoveToWindow(view, token: captureToken)
            }
        )
        panel.attach(view, token: captureToken)
        panel.setCaptureVisibleInUI(isVisibleInUI, token: captureToken)
        return view
    }

    func updateNSView(_ nsView: ApplicationCaptureView, context: Context) {
        guard let captureToken = context.coordinator.captureToken else {
            nsView.stopCapture()
            return
        }
        panel.setCaptureVisibleInUI(isVisibleInUI, token: captureToken)
    }

    static func dismantleNSView(_ nsView: ApplicationCaptureView, coordinator: Coordinator) {
        guard let panel = coordinator.panel,
              let captureToken = coordinator.captureToken else {
            nsView.stopCapture()
            return
        }
        panel.detach(nsView, token: captureToken)
        coordinator.captureToken = nil
    }
}
