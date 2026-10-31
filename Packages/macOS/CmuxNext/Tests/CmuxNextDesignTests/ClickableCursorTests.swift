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

        func recordedRects() -> [(rect: NSRect, cursor: NSCursor)] {
            rects = []
            resetCursorRects()
            return rects
        }
    }

    /// A window whose content holds `container` (clipping, 50 x 50) with `button` at `frame` in it.
    private func host(_ button: NSView, at frame: NSRect) -> (window: NSWindow, container: NSView) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 200), styleMask: [.borderless],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 50, height: 50))
        container.clipsToBounds = true
        window.contentView?.addSubview(container)
        container.addSubview(button)
        button.frame = frame
        return (window, container)
    }

    @Test func anEnabledButtonRegistersThePointingHandOverItsBounds() {
        let button = RecordingButton(frame: .zero)
        let host = host(button, at: NSRect(x: 0, y: 0, width: 40, height: 20))
        let rects = button.recordedRects()
        #expect(rects.count == 1)
        #expect(rects.first?.rect == button.bounds)
        #expect(rects.first?.cursor === NSCursor.pointingHand)
        withExtendedLifetime(host) {}
    }

    @Test func aDisabledButtonRegistersNoCursorAndKeepsTheArrow() {
        let button = RecordingButton(frame: .zero)
        let host = host(button, at: NSRect(x: 0, y: 0, width: 40, height: 20))
        button.isEnabled = false
        #expect(button.recordedRects().isEmpty)
        #expect(ClickableButton.hoverCursor(isEnabled: false) == nil)
        #expect(ClickableButton.hoverCursor(isEnabled: true) === NSCursor.pointingHand)
        withExtendedLifetime(host) {}
    }

    @Test func reEnablingAButtonRegistersTheHandAgain() {
        let button = RecordingButton(frame: .zero)
        let host = host(button, at: NSRect(x: 0, y: 0, width: 40, height: 20))
        button.isEnabled = false
        #expect(button.recordedRects().isEmpty)
        button.isEnabled = true
        #expect(button.recordedRects().map(\.cursor) == [NSCursor.pointingHand])
        withExtendedLifetime(host) {}
    }

    /// A button its container clips claims the hand only over the part that shows.
    @Test func aClippedButtonRegistersOnlyItsVisibleRect() {
        let button = RecordingButton(frame: .zero)
        let host = host(button, at: NSRect(x: 30, y: 0, width: 40, height: 20))
        let rects = button.recordedRects()
        #expect(rects.count == 1)
        #expect(rects.first?.rect == NSRect(x: 0, y: 0, width: 20, height: 20))
        withExtendedLifetime(host) {}
    }

    @Test func aButtonClippedOutOfViewRegistersNone() {
        let button = RecordingButton(frame: .zero)
        let host = host(button, at: NSRect(x: 60, y: 0, width: 40, height: 20))
        #expect(button.recordedRects().isEmpty)
        withExtendedLifetime(host) {}
    }

    @Test func aHiddenButtonOrOneUnderAHiddenAncestorRegistersNone() {
        let button = RecordingButton(frame: .zero)
        let host = host(button, at: NSRect(x: 0, y: 0, width: 40, height: 20))
        button.isHidden = true
        #expect(button.recordedRects().isEmpty)
        button.isHidden = false
        host.container.isHidden = true
        #expect(button.recordedRects().isEmpty)
        host.container.isHidden = false
        #expect(button.recordedRects().count == 1)
        withExtendedLifetime(host) {}
    }

    /// macOS 14's SwiftUI fallback: disabling under the pointer pops the hand, and re-enabling
    /// under the still pointer pushes it again; every push has one pop.
    @Test func theFallbackPushesAgainOnAReEnableUnderTheStillPointer() {
        var hover = ClickableCursorHover()
        #expect(hover.update(hovering: true, enabled: true) == .push)
        #expect(hover.update(hovering: true, enabled: false) == .pop)
        #expect(hover.update(hovering: true, enabled: true) == .push)
        #expect(hover.update(hovering: true, enabled: true) == nil)
        #expect(hover.update(hovering: false, enabled: true) == .pop)
        #expect(hover.update(hovering: false, enabled: false) == nil)
        #expect(hover.update(hovering: false, enabled: true) == nil)
    }

    @Test func theFallbackNeverPushesForADisabledViewAndPopsWhenTheViewGoesAway() {
        var hover = ClickableCursorHover()
        #expect(hover.update(hovering: true, enabled: false) == nil)
        #expect(hover.update(hovering: true, enabled: true) == .push)
        // `onDisappear` mid-hover.
        #expect(hover.update(hovering: false, enabled: true) == .pop)
        #expect(!hover.pushed)
    }

    @Test func theFallbackKeepsPushesAndPopsBalancedOverAnySequence() {
        var hover = ClickableCursorHover()
        var depth = 0
        let steps: [(Bool, Bool)] = [(true, true), (true, false), (false, false), (true, false), (true, true), (true, true),
                                     (false, true), (true, true), (true, false), (true, true), (false, false)]
        for (hovering, enabled) in steps {
            switch hover.update(hovering: hovering, enabled: enabled) {
            case .push: depth += 1
            case .pop: depth -= 1
            case nil: break
            }
            #expect(depth == (hovering && enabled ? 1 : 0))
        }
        #expect(depth == 0)
    }

    /// The real conversion and topmost-window gate: a screen point becomes the window's point
    /// only while the window is the top one under it.
    @Test func thePointerIsReadInWindowCoordinatesOnlyInTheTopWindow() {
        let window = NSWindow(contentRect: NSRect(x: 100, y: 200, width: 300, height: 60), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        var asked: NSPoint?
        let point = ClickableButton.pointer(in: window, screenPoint: NSPoint(x: 110, y: 215)) {
            asked = $0
            return window.windowNumber
        }
        #expect(point == NSPoint(x: 10, y: 15))
        #expect(asked == NSPoint(x: 110, y: 215))
        #expect(ClickableButton.pointer(in: window, screenPoint: NSPoint(x: 110, y: 215)) { _ in window.windowNumber + 1 } == nil)
    }

    /// The shared clickable buttons of this module are `ClickableButton`s.
    @Test func theSharedDesignButtonsAreClickableButtons() {
        let shared: [NSButton.Type] = [ThemedBezelButton.self, ThemedDefaultButton.self, TitlebarBandButton.self, OverflowButton.self,
                                       CmuxToastButton.self, CmuxDialogButtonView.self, FindPillButton.self]
        for type in shared {
            let inherits = type is ClickableButton.Type
            #expect(inherits, "\(type) must inherit ClickableButton")
        }
    }

    /// Static guard: the shared clickable buttons and SwiftUI button styles of modules this test
    /// target cannot import use the shared cursor (the browser's buttons are checked by behavior
    /// in `OmnibarPointerButtonTests`). A new shared button or style belongs on this list.
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
            ("CmuxNextTabs/NewTabButtonView.swift", "ClickableButton.cursorRect(of: self)"),
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
