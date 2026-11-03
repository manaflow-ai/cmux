import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import Testing
import CmuxNextTestSupport

/// REOPEN-F7: each workspace row's hover-only icon buttons registered their themed tooltip at init (a tracker in
/// the tooltip table and a tracking area), before the window's first frame, though a hidden button cannot be
/// hovered. A hidden button registers its tooltip when it first shows; VoiceOver's help is there from the start.
@MainActor @Suite(.closesItsWindows, .serialized) struct SidebarIconButtonLazyTooltipTests {
    private static func window() -> NSWindow {
        NSWindow(contentRect: NSRect(x: 200, y: 400, width: 300, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
    }

    @Test func aHiddenButtonRegistersNoTooltipUntilItShows() throws {
        let window = Self.window()
        let button = SidebarIconButton(icon: .actionClose, label: "Close Workspace")
        button.isHidden = true
        try #require(window.contentView).addSubview(button)
        #expect(TooltipTracker.all(of: button).isEmpty, "a hidden button registered its tooltip")
        #expect(button.accessibilityHelp() == "Close Workspace", "VoiceOver lost the help of a hidden button")
        button.isHidden = false
        #expect(button.themedToolTip == "Close Workspace", "a shown button has no tooltip")
        #expect(TooltipTracker.all(of: button).count == 1)
    }

    @Test func aLabelChangeWhileHiddenShowsTheNewLabel() throws {
        let window = Self.window()
        let button = SidebarIconButton(icon: .actionClose, label: "Close Workspace")
        button.isHidden = true
        try #require(window.contentView).addSubview(button)
        button.label = "Close Tab"
        #expect(TooltipTracker.all(of: button).isEmpty)
        #expect(button.accessibilityHelp() == "Close Tab")
        button.isHidden = false
        #expect(button.themedToolTip == "Close Tab")
    }

    @Test func aButtonThatNamesItselfGetsNoTooltipWhenShown() throws {
        let window = Self.window()
        let button = SidebarIconButton(icon: .actionClose, label: "Close")
        button.showsLabelToolTip = false
        try #require(window.contentView).addSubview(button)
        #expect(button.themedToolTip == nil)
    }
}
