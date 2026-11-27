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
        #expect(!Self.tracksTooltip(button), "a hidden button tracks its tooltip")
        #expect(button.accessibilityHelp() == "Close Workspace", "VoiceOver lost the help of a hidden button")
        button.isHidden = false
        #expect(button.themedToolTip == "Close Workspace", "a shown button has no tooltip")
        #expect(Self.tracksTooltip(button))
    }

    @Test func aLabelChangeWhileHiddenShowsTheNewLabel() throws {
        let window = Self.window()
        let button = SidebarIconButton(icon: .actionClose, label: "Close Workspace")
        button.isHidden = true
        try #require(window.contentView).addSubview(button)
        button.label = "Close Tab"
        #expect(!Self.tracksTooltip(button))
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

    /// Review of #33113 (P1): a shortcut set while the button is hidden or has no window (the Priority bell, set by
    /// `showPriority` on a sidebar not yet in a window) was dropped, so the bell's tooltip lost its "⌥⌘K". The text and
    /// the shortcut read back at once in every state; only the hover tracking waits for the button to show.
    @Test func aShortcutSetBeforeTheButtonShowsIsKept() throws {
        let button = SidebarIconButton(icon: .notification, label: "Show Priority")
        button.isHidden = true
        button.themedToolTipShortcut = "⌥⌘K"
        #expect(button.themedToolTip == "Show Priority")
        #expect(button.themedToolTipShortcut == "⌥⌘K")
        let window = Self.window()
        try #require(window.contentView).addSubview(button)
        button.isHidden = false
        #expect(button.themedToolTip == "Show Priority")
        #expect(button.themedToolTipShortcut == "⌥⌘K", "the shortcut set while hidden was dropped")
    }

    /// The tooltip reads back with no window too (a view built before it is installed), and the hover tracking area
    /// waits until the button is in a window and shown.
    @Test func theTooltipReadsBackBeforeAWindowAndTracksOnlyOnceShown() throws {
        let button = SidebarIconButton(icon: .actionClose, label: "Close Workspace")
        #expect(button.themedToolTip == "Close Workspace")
        #expect(button.accessibilityHelp() == "Close Workspace")
        #expect(!Self.tracksTooltip(button), "a button with no window tracks its tooltip")
        let window = Self.window()
        button.isHidden = true
        try #require(window.contentView).addSubview(button)
        #expect(!Self.tracksTooltip(button), "a hidden button tracks its tooltip")
        button.isHidden = false
        #expect(Self.tracksTooltip(button), "a shown button does not track its tooltip")
    }

    /// Whether the view has a tooltip tracking area (owned by a `TooltipTracker`).
    private static func tracksTooltip(_ view: NSView) -> Bool {
        view.trackingAreas.contains { $0.owner is TooltipTracker }
    }
}
