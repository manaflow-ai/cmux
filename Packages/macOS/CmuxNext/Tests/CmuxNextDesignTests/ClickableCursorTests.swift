import AppKit
@testable import CmuxNextDesign
import Foundation
import Testing

/// Clickable chrome shows the pointing hand (Leo 2026-10-21: "STOP BUTTON, I HOVER OVER IT, MY
/// CURSOR SHOULD ALSO SEE IT AS CLICKABLE.. LOTS OF AREAS LIKE THAT SHOULD BE CHANGING MY CURSOR
/// INDICATOR TO CLICKABLE"). One shared button class registers the cursor rect; the shared
/// buttons and SwiftUI button styles adopt it.
@MainActor
struct ClickableCursorTests {
    /// Records the cursor rects a button registers instead of handing them to a window.
    private final class RecordingButton: ClickableButton {
        var rects: [(rect: NSRect, cursor: NSCursor)] = []
        override func addCursorRect(_ rect: NSRect, cursor object: NSCursor) { rects.append((rect, object)) }
    }

    @Test func anEnabledButtonRegistersThePointingHandOverItsBounds() {
        let button = RecordingButton(frame: NSRect(x: 0, y: 0, width: 40, height: 20))
        button.resetCursorRects()
        #expect(button.rects.count == 1)
        #expect(button.rects.first?.rect == button.bounds)
        #expect(button.rects.first?.cursor === NSCursor.pointingHand)
    }

    @Test func aDisabledButtonRegistersNoCursorAndKeepsTheArrow() {
        let button = RecordingButton(frame: NSRect(x: 0, y: 0, width: 40, height: 20))
        button.isEnabled = false
        button.resetCursorRects()
        #expect(button.rects.isEmpty)
        #expect(ClickableButton.hoverCursor(isEnabled: false) == nil)
        #expect(ClickableButton.hoverCursor(isEnabled: true) === NSCursor.pointingHand)
    }

    @Test func reEnablingAButtonRegistersTheHandAgain() {
        let button = RecordingButton(frame: NSRect(x: 0, y: 0, width: 40, height: 20))
        button.isEnabled = false
        button.isEnabled = true
        button.resetCursorRects()
        #expect(button.rects.map(\.cursor) == [NSCursor.pointingHand])
    }

    /// The shared clickable buttons of this module are `ClickableButton`s.
    @Test func theSharedDesignButtonsAreClickableButtons() {
        let shared: [AnyClass] = [ThemedBezelButton.self, ThemedDefaultButton.self, TitlebarBandButton.self, OverflowButton.self,
                                  CmuxToastButton.self, CmuxDialogButtonView.self, FindPillButton.self]
        for type in shared {
            #expect(type.isSubclass(of: ClickableButton.self), "\(type) must inherit ClickableButton")
        }
    }

    /// Static guard: the shared clickable buttons and SwiftUI button styles of other modules use
    /// the shared cursor. A new shared button or style belongs on this list.
    @Test func theSharedButtonsAndStylesElsewhereUseTheClickableCursor() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
        let required: [(path: String, needle: String)] = [
            ("CmuxNextSidebar/Views/SidebarIconButton.swift", "class SidebarIconButton: ClickableButton"),
            ("CmuxNextHome/Sidebar/HomeHeaderButton.swift", "class HomeHeaderButton: ClickableButton"),
            ("CmuxNextHome/Sidebar/HomeChatComposeButton.swift", "class HomeChatComposeButton: ClickableButton"),
            ("CmuxNextAgentQuestion/AgentQuestionPillButton.swift", "class AgentQuestionPillButton: ClickableButton"),
            ("CmuxNextTerminal/TerminalRestartButton.swift", "class TerminalRestartButton: ClickableButton"),
            ("CmuxNextTerminal/TerminalRetryButton.swift", "class TerminalRetryButton: ClickableButton"),
            ("CmuxNextTabs/NewTabButtonView.swift", "addCursorRect(bounds, cursor: .pointingHand)"),
            ("CmuxNextDesign/GlassButtonStyle.swift", ".clickableCursor()"),
            ("CmuxNextFeed/Views/FeedButtonStyle.swift", ".clickableCursor()"),
            ("CmuxNextSettingsWindow/Views/SettingsStyle.swift", ".clickableCursor()"),
            ("CmuxNextAccounts/Views/AccountsPalette.swift", ".clickableCursor()"),
        ]
        for item in required {
            let text = try String(contentsOf: sources.appendingPathComponent(item.path), encoding: .utf8)
            #expect(text.contains(item.needle), "\(item.path) must contain `\(item.needle)`")
        }
    }
}
