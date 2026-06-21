public import SwiftUI

/// The Move Up / Move Down context-menu pair for a row in an extension sidebar's
/// browser-stack column.
///
/// Drained byte-identically from
/// `VerticalTabsSidebar.extensionBrowserStackReorderMenu` in the app target. The
/// owning view attaches this as a tile's or row's `.contextMenu`. Each button
/// forwards to an injected closure (the app shifts the workspace one position in
/// the provider's ordered drop rows), so this package view holds no provider or
/// drag-state dependency.
public struct ExtensionBrowserStackReorderMenu: View {
    let onMoveUp: () -> Void
    let onMoveDown: () -> Void

    /// Creates the reorder context menu.
    /// - Parameters:
    ///   - onMoveUp: Invoked when the user picks Move Up (shift the row toward the
    ///     start of the stack).
    ///   - onMoveDown: Invoked when the user picks Move Down (shift the row toward
    ///     the end of the stack).
    public init(onMoveUp: @escaping () -> Void, onMoveDown: @escaping () -> Void) {
        self.onMoveUp = onMoveUp
        self.onMoveDown = onMoveDown
    }

    public var body: some View {
        Button(String(localized: "contextMenu.moveUp", defaultValue: "Move Up", bundle: .main)) {
            onMoveUp()
        }
        Button(String(localized: "contextMenu.moveDown", defaultValue: "Move Down", bundle: .main)) {
            onMoveDown()
        }
    }
}
