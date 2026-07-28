import AppKit
import SwiftUI

struct ApplicationCaptureRepresentable: NSViewRepresentable {
    let panel: ApplicationPanel
    let windowID: CGWindowID
    let processID: pid_t
    let isVisibleInUI: Bool

    func makeNSView(context: Context) -> ApplicationCaptureView {
        let view = panel.captureView(
            windowID: windowID,
            processID: processID
        )
        panel.setCaptureVisibleInUI(isVisibleInUI, view: view)
        return view
    }

    func updateNSView(_ nsView: ApplicationCaptureView, context: Context) {
        panel.setCaptureVisibleInUI(isVisibleInUI, view: nsView)
    }
}
