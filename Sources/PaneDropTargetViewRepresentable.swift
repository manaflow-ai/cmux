import AppKit
import SwiftUI

typealias TerminalPaneDropTargetView = PaneDropTargetView

struct PaneDropTargetRepresentable: NSViewRepresentable {
    let dropContext: PaneDropContext?
    let paneDropTargetRegistry: PaneDropTargetRegistry

    func makeNSView(context: Context) -> PaneDropTargetView {
        PaneDropTargetView(frame: .zero, paneDropTargetRegistry: paneDropTargetRegistry)
    }

    func updateNSView(_ nsView: PaneDropTargetView, context: Context) {
        nsView.dropContext = dropContext
        nsView.hostedView = nil
        if dropContext == nil {
            nsView.draggingExited(nil)
        }
    }
}
