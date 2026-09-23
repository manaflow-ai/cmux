import AppKit
import SwiftUI

struct ForeignWindowSurface: NSViewRepresentable {
    let panelID: UUID
    let profile: String
    let registry: ForeignWindowProfileRegistry
    let isFocused: Bool
    let isVisibleInUI: Bool
    let backgroundColor: NSColor
    let onRequestPanelFocus: () -> Void

    func makeNSView(context: Context) -> ForeignWindowHostView {
        ForeignWindowHostView(
            panelID: panelID,
            profile: profile,
            registry: registry
        )
    }

    func updateNSView(
        _ nsView: ForeignWindowHostView,
        context: Context
    ) {
        _ = context
        nsView.onRequestPanelFocus = onRequestPanelFocus
        nsView.update(
            isFocused: isFocused,
            isVisibleInUI: isVisibleInUI,
            backgroundColor: backgroundColor
        )
    }

    static func dismantleNSView(
        _ nsView: ForeignWindowHostView,
        coordinator: ()
    ) {
        _ = coordinator
        // Detach only; the panel's close path ends the process.
        nsView.detach()
    }
}
