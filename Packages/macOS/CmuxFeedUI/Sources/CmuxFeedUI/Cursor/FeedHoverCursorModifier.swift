public import SwiftUI
public import AppKit

/// A `ViewModifier` that swaps the pointer to a given `NSCursor` while the
/// pointer is over the modified view, restoring the previous cursor on exit
/// or disappearance.
///
/// The push/pop is balanced via the internal `cursorPushed` flag so a view
/// that disappears while hovered does not leak a pushed cursor onto the
/// AppKit cursor stack.
public struct FeedHoverCursorModifier: ViewModifier {
    let enabled: Bool
    let cursor: NSCursor

    @State private var cursorPushed = false

    /// Creates a hover-cursor modifier.
    /// - Parameters:
    ///   - enabled: When `false`, hovering does not change the cursor.
    ///   - cursor: The cursor to push while hovered.
    public init(enabled: Bool, cursor: NSCursor) {
        self.enabled = enabled
        self.cursor = cursor
    }

    public func body(content: Content) -> some View {
        content
            .onHover { hovering in
                if hovering, enabled {
                    pushIfNeeded()
                } else {
                    popIfNeeded()
                }
            }
            .onDisappear {
                popIfNeeded()
            }
    }

    private func pushIfNeeded() {
        guard !cursorPushed else { return }
        cursor.push()
        cursorPushed = true
    }

    private func popIfNeeded() {
        guard cursorPushed else { return }
        NSCursor.pop()
        cursorPushed = false
    }
}

extension View {
    /// Shows an I-beam cursor while the pointer is over this view.
    /// - Parameter enabled: When `false`, the cursor is left unchanged.
    public func feedIBeamCursorOnHover(enabled: Bool) -> some View {
        modifier(FeedHoverCursorModifier(enabled: enabled, cursor: .iBeam))
    }
}
