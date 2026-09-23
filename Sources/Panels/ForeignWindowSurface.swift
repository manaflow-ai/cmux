import AppKit
import SwiftUI

struct ForeignWindowSurface: NSViewRepresentable {
    let surfaceID: UUID
    let launchConfiguration: ForeignWindowLaunchConfiguration
    let isFocused: Bool
    let isVisibleInUI: Bool
    let backgroundColor: NSColor

    func makeNSView(context: Context) -> ForeignWindowHostView {
        ForeignWindowHostView(
            surfaceID: surfaceID,
            launchConfiguration: launchConfiguration
        )
    }

    func updateNSView(
        _ nsView: ForeignWindowHostView,
        context: Context
    ) {
        _ = context
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
        nsView.invalidate()
    }
}
