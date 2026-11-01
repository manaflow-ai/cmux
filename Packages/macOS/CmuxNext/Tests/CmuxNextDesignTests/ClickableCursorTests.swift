import AppKit
@testable import CmuxNextDesign
import CmuxNextTestSupport
import Foundation
import Testing

/// Clickable chrome shows the arrow, as native macOS apps do (user 2026-10-30: "change all
/// pointers back to cursor-default"). The shared button class registers no cursor rect of its
/// own, enabled or not, so the arrow shows over every button that inherits it.
/// `scripts/cmux-next/check-default-cursor.py` keeps new pointing hands out of the sources.
@Suite(.closesItsWindows)
@MainActor
struct ClickableCursorTests {
    /// Records the cursor rects a button registers instead of handing them to a window.
    private final class RecordingButton: ClickableButton {
        var rects: [(rect: NSRect, cursor: NSCursor)] = []
        override func addCursorRect(_ rect: NSRect, cursor object: NSCursor) { rects.append((rect, object)) }

        func recordedRects() -> [(rect: NSRect, cursor: NSCursor)] {
            rects = []
            resetCursorRects()
            return rects
        }
    }

    /// A window whose content holds `button` at `frame`.
    private func host(_ button: NSView, at frame: NSRect) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 200), styleMask: [.borderless],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView?.addSubview(button)
        button.frame = frame
        return window
    }

    @Test func anEnabledButtonRegistersNoCursorSoTheArrowShows() {
        let button = RecordingButton(frame: .zero)
        let window = host(button, at: NSRect(x: 0, y: 0, width: 40, height: 20))
        defer { window.closeAfterTest() }
        #expect(button.recordedRects().isEmpty)
        withExtendedLifetime(window) {}
    }

    @Test func aDisabledOrReEnabledButtonRegistersNoCursor() {
        let button = RecordingButton(frame: .zero)
        let window = host(button, at: NSRect(x: 0, y: 0, width: 40, height: 20))
        defer { window.closeAfterTest() }
        button.isEnabled = false
        #expect(button.recordedRects().isEmpty)
        button.isEnabled = true
        #expect(button.recordedRects().isEmpty)
        withExtendedLifetime(window) {}
    }

    /// The shared clickable buttons of this module are `ClickableButton`s, so they share its arrow.
    @Test func theSharedDesignButtonsAreClickableButtons() {
        let shared: [NSButton.Type] = [ThemedBezelButton.self, ThemedDefaultButton.self, TitlebarBandButton.self, OverflowButton.self,
                                       CmuxToastButton.self, CmuxDialogButtonView.self, FindPillButton.self]
        for type in shared {
            let inherits = type is ClickableButton.Type
            #expect(inherits, "\(type) must inherit ClickableButton")
        }
    }
}
