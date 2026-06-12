import AppKit

/// A value snapshot describing one pane the canvas should display.
///
/// Built by the SwiftUI container on every update pass; the canvas root view
/// diffs descriptors against its current pane views, so SwiftUI state changes
/// flow into AppKit without the canvas observing any store.
@MainActor
struct CanvasPaneDescriptor: Identifiable {
    let id: UUID
    let title: String
    let iconSystemName: String?
    let isFocused: Bool
    /// Creates the panel's content mount target. Called once per mount.
    let makeContent: () -> CanvasPaneContent

    var chrome: CanvasPaneView.Chrome {
        CanvasPaneView.Chrome(title: title, iconSystemName: iconSystemName, isFocused: isFocused)
    }
}

/// The callbacks the canvas needs from its owning workspace.
@MainActor
struct CanvasHostCallbacks {
    let onFocusPanel: (UUID) -> Void
    let onClosePanel: (UUID) -> Void
    let onLayoutChanged: () -> Void
}
