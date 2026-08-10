import AppKit
public import SwiftUI

/// A transparent overlay that presents an AppKit context menu on right-click /
/// control-click, avoiding SwiftUI's leaky `.contextMenu` bridge.
public struct AppKitContextMenuCapture: NSViewRepresentable {
    /// Builds the menu elements fresh on each invocation (right-click).
    public let elements: @MainActor () -> [CmuxContextMenuElement]

    /// Creates the overlay.
    /// - Parameter elements: Builds the menu elements on demand; should capture
    ///   model state above the row's snapshot boundary and return value-typed
    ///   elements only.
    public init(elements: @escaping @MainActor () -> [CmuxContextMenuElement]) {
        self.elements = elements
    }

    /// Creates the backing capture view.
    public func makeNSView(context: Context) -> AppKitContextMenuCaptureView {
        let view = AppKitContextMenuCaptureView()
        view.elementsProvider = elements
        return view
    }

    /// Refreshes the element provider so the menu reflects current state.
    public func updateNSView(_ nsView: AppKitContextMenuCaptureView, context: Context) {
        nsView.elementsProvider = elements
    }
}

extension View {
    /// Attaches an AppKit `NSMenu`-backed context menu instead of SwiftUI's
    /// `.contextMenu`.
    ///
    /// Use this on high-churn list rows (created/destroyed as data changes) to
    /// avoid the per-attachment SwiftUI `ContextMenuResponder` retain cycle
    /// (https://github.com/manaflow-ai/cmux/issues/5953). The `elements` closure
    /// is invoked fresh on each right-click, so it should capture model state
    /// above the row's snapshot boundary and return value-typed elements only.
    /// - Parameter elements: Builds the menu elements on demand.
    public func cmuxAppKitContextMenu(
        _ elements: @escaping @MainActor () -> [CmuxContextMenuElement]
    ) -> some View {
        overlay(AppKitContextMenuCapture(elements: elements))
    }
}
