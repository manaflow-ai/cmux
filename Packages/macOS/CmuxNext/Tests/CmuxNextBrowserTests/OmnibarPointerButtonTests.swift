import AppKit
@testable import CmuxNextBrowser
import CmuxNextDesign
import Testing

/// The browser toolbar's buttons show the pointing hand like the rest of the chrome (Leo
/// 2026-10-21: "STOP BUTTON, I HOVER OVER IT, MY CURSOR SHOULD ALSO SEE IT AS CLICKABLE"): the
/// toolbar row sets the cursor on every pointer move (`ArrowCursorView`), so its rule
/// (`OmnibarPointer.cursor(atWindowPoint:in:)`) must give the hand over an enabled button instead
/// of the row's arrow, and the arrow over a disabled one.
@MainActor
struct OmnibarPointerButtonTests {
    private func row(with button: NSView) -> (window: NSWindow, row: ArrowCursorView) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 60), styleMask: [.borderless],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let row = ArrowCursorView(frame: NSRect(x: 0, y: 0, width: 300, height: 40))
        window.contentView?.addSubview(row)
        row.addSubview(button)
        button.frame = NSRect(x: 10, y: 5, width: 30, height: 30)
        return (window, row)
    }

    private func windowPoint(atCenterOf view: NSView) -> NSPoint {
        view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
    }

    @Test func anEnabledToolbarButtonShowsThePointingHand() {
        let button = ChromeIconButton(icon: .navPreviousMatch, label: "Back", action: nil, target: nil, toolbar: true)
        let host = row(with: button)
        #expect(OmnibarPointer.cursor(atWindowPoint: windowPoint(atCenterOf: button), in: host.row) == .pointingHand)
        #expect(OmnibarPointer.Cursor.pointingHand.cursor === NSCursor.pointingHand)
        withExtendedLifetime(host) {}
    }

    @Test func aDisabledToolbarButtonKeepsTheArrow() {
        let button = ChromeIconButton(icon: .navPreviousMatch, label: "Back", action: nil, target: nil, toolbar: true)
        let host = row(with: button)
        button.isEnabled = false
        #expect(OmnibarPointer.cursor(atWindowPoint: windowPoint(atCenterOf: button), in: host.row) == .arrow)
        withExtendedLifetime(host) {}
    }

    @Test func theRowBesideAButtonKeepsTheArrow() {
        let button = ChromeIconButton(icon: .navPreviousMatch, label: "Back", action: nil, target: nil, toolbar: true)
        let host = row(with: button)
        let beside = host.row.convert(NSPoint(x: 200, y: 20), to: nil)
        #expect(OmnibarPointer.cursor(atWindowPoint: beside, in: host.row) == .arrow)
        withExtendedLifetime(host) {}
    }

    /// Back runs out of history under a still pointer while a Chromium page has the key: the
    /// row's cursor follows the button at once (no move, no key window to rebuild cursor rects).
    @Test func aButtonDisabledOrEnabledUnderTheStillPointerChangesTheRowsCursor() {
        let button = ChromeIconButton(icon: .navPreviousMatch, label: "Back", action: nil, target: nil, toolbar: true)
        let host = row(with: button)
        host.row.setCursor(at: windowPoint(atCenterOf: button))
        #expect(host.row.trackedCursor == .pointingHand)
        button.isEnabled = false
        #expect(host.row.trackedCursor == .arrow)
        button.isEnabled = true
        #expect(host.row.trackedCursor == .pointingHand)
        withExtendedLifetime(host) {}
    }

    @Test func aButtonChangingStateWithNoPointerOverTheRowSetsNoCursor() {
        let button = ChromeIconButton(icon: .navPreviousMatch, label: "Back", action: nil, target: nil, toolbar: true)
        let host = row(with: button)
        button.isEnabled = false
        button.isEnabled = true
        #expect(host.row.trackedCursor == nil)
        withExtendedLifetime(host) {}
    }

    @Test func aPinnedExtensionButtonShowsThePointingHand() {
        let button = ExtensionActionButton(actionID: "test-extension")
        let host = row(with: button)
        #expect(OmnibarPointer.cursor(atWindowPoint: windowPoint(atCenterOf: button), in: host.row) == .pointingHand)
        withExtendedLifetime(host) {}
    }

    @Test func theBookmarkStarShowsThePointingHand() {
        let star = BookmarkStarButton(frame: .zero)
        star.state = .off
        let host = row(with: star)
        #expect(OmnibarPointer.cursor(atWindowPoint: windowPoint(atCenterOf: star), in: host.row) == .pointingHand)
        withExtendedLifetime(host) {}
    }

    @Test func theChromeButtonsAreClickableButtons() {
        let icon: NSButton = ChromeIconButton(icon: .navPreviousMatch, label: "Back", action: nil, target: nil)
        let text: NSButton = ChromeTextButton(title: "Retry", prominent: false, action: nil, target: nil)
        #expect(icon is ClickableButton)
        #expect(text is ClickableButton)
        let extensionButton: NSButton = ExtensionActionButton(actionID: "test-extension")
        #expect(extensionButton is ClickableButton)
        #expect(OmnibarPointer.cursor(.button) == .pointingHand)
        #expect(OmnibarPointer.cursor(.control) == .arrow)
    }
}
