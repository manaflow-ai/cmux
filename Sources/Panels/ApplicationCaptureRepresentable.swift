import AppKit
import Foundation
import SwiftUI

struct ApplicationCaptureRepresentable: NSViewRepresentable {
    let panel: ApplicationPanel
    let windowID: CGWindowID
    let processID: pid_t
    let isVisibleInUI: Bool
    let allowsPointerInput: Bool

    func makeCoordinator() -> UUID {
        UUID()
    }

    func makeNSView(context: Context) -> ApplicationCaptureView {
        let view = panel.captureView(
            windowID: windowID,
            processID: processID
        )
        panel.updateCaptureViewMount(
            isVisibleInUI: isVisibleInUI,
            allowsPointerInput: allowsPointerInput,
            view: view,
            mountID: context.coordinator
        )
        return view
    }

    func updateNSView(_ nsView: ApplicationCaptureView, context: Context) {
        panel.updateCaptureViewMount(
            isVisibleInUI: isVisibleInUI,
            allowsPointerInput: allowsPointerInput,
            view: nsView,
            mountID: context.coordinator
        )
    }

    static func dismantleNSView(
        _ nsView: ApplicationCaptureView,
        coordinator: UUID
    ) {
        nsView.representableWasDismantled(mountID: coordinator)
    }
}
