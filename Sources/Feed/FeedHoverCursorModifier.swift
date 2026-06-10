import AppKit
import Bonsplit
import CMUXWorkstream
import SwiftUI

private struct FeedHoverCursorModifier: ViewModifier {
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
    func feedIBeamCursorOnHover(enabled: Bool) -> some View {
        modifier(FeedHoverCursorModifier(enabled: enabled, cursor: .iBeam))
    }
}

