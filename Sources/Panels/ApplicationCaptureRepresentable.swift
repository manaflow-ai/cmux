import AppKit
import SwiftUI

struct ApplicationCaptureRepresentable: NSViewRepresentable {
    let panel: ApplicationPanel
    let windowID: CGWindowID
    let processID: pid_t
    let isVisibleInUI: Bool
    let allowsPointerInput: Bool

    func makeNSView(context: Context) -> ApplicationCaptureView {
        let view = panel.captureView(
            windowID: windowID,
            processID: processID
        )
        view.setInputOwnership(allowsPointerInput)
        panel.setCaptureVisibleInUI(isVisibleInUI, view: view)
        return view
    }

    func updateNSView(_ nsView: ApplicationCaptureView, context: Context) {
        nsView.setInputOwnership(allowsPointerInput)
        panel.setCaptureVisibleInUI(isVisibleInUI, view: nsView)
    }

    static func dismantleNSView(
        _ nsView: ApplicationCaptureView,
        coordinator: ()
    ) {
        nsView.setInputOwnership(false)
        nsView.representableWasDismantled()
    }
}
