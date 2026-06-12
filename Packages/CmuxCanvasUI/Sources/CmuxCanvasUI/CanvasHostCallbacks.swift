public import Foundation

/// The callbacks the canvas needs from its owning host (the workspace).
@MainActor
public struct CanvasHostCallbacks {
    public let onFocusPanel: (UUID) -> Void
    public let onClosePanel: (UUID) -> Void
    public let onLayoutChanged: () -> Void

    public init(
        onFocusPanel: @escaping (UUID) -> Void,
        onClosePanel: @escaping (UUID) -> Void,
        onLayoutChanged: @escaping () -> Void
    ) {
        self.onFocusPanel = onFocusPanel
        self.onClosePanel = onClosePanel
        self.onLayoutChanged = onLayoutChanged
    }
}
