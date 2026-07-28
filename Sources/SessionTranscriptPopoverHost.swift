import AppKit
import SwiftUI

struct SessionTranscriptPopoverHost: NSViewRepresentable {
    @Binding var isPresented: Bool
    let entry: SessionEntry

    func makeCoordinator() -> SessionTranscriptPopoverCoordinator {
        SessionTranscriptPopoverCoordinator(isPresented: $isPresented)
    }

    func makeNSView(context: Context) -> PopoverAnchorView {
        let view = PopoverAnchorView()
        view.translatesAutoresizingMaskIntoConstraints = false
        context.coordinator.anchorView = view
        view.onDidMoveToWindow = { [weak coordinator = context.coordinator] in
            coordinator?.anchorDidMoveToWindow()
        }
        return view
    }

    func updateNSView(_ nsView: PopoverAnchorView, context: Context) {
        let coordinator = context.coordinator
        coordinator.anchorView = nsView
        coordinator.update(entry: entry)
        if isPresented {
            coordinator.present()
        } else {
            coordinator.dismiss()
        }
    }

    static func dismantleNSView(
        _ nsView: PopoverAnchorView,
        coordinator: SessionTranscriptPopoverCoordinator
    ) {
        nsView.onDidMoveToWindow = nil
        coordinator.dismiss()
    }
}
