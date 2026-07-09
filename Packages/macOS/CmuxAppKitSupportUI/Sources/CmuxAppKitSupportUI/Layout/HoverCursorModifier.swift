import AppKit
public import SwiftUI

/// A view modifier that pushes an `NSCursor` while the pointer hovers the content
/// and pops it back on exit (or when the view disappears).
///
/// The cursor is pushed at most once per hover session via the ``cursorPushed``
/// latch, and always balanced with a matching pop, so overlapping hover/disappear
/// transitions never leave the AppKit cursor stack unbalanced.
struct HoverCursorModifier: ViewModifier {
    let enabled: Bool
    let cursor: NSCursor

    @State private var cursorPushed = false

    func body(content: Content) -> some View {
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
    /// Shows the I-beam cursor while the pointer hovers this view, when `enabled`.
    /// - Parameter enabled: Whether hovering should swap in the I-beam cursor.
    public func feedIBeamCursorOnHover(enabled: Bool) -> some View {
        modifier(HoverCursorModifier(enabled: enabled, cursor: .iBeam))
    }
}
