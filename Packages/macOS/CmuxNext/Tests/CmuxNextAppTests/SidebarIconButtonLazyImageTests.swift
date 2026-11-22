import AppKit
import CmuxNextIcons
@testable import CmuxNextSidebar
import Testing
import CmuxNextTestSupport

/// REOPEN-F7: a reopened window's sidebar makes 5 icon buttons per workspace row (close, audio, pin, tree fold,
/// more) and they stay hidden until the pointer is on the row. Each made its icon image when it was made: about
/// 4 ms of the profiled window build before the first frame (`SidebarIconButton.renderIcon`). A hidden button
/// needs no image; it makes it when it first shows.
@MainActor @Suite(.closesItsWindows, .serialized) struct SidebarIconButtonLazyImageTests {
    /// The button's icon image: AppKit answers a button with no image of its own with a shared 1 x 1
    /// placeholder, so "no icon yet" is no image at least 2 points wide.
    private static func icon(of button: SidebarIconButton) -> NSImage? {
        button.image.flatMap { $0.size.width > 1 ? $0 : nil }
    }

    private static func window() -> NSWindow {
        NSWindow(contentRect: NSRect(x: 200, y: 400, width: 300, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
    }

    @Test func aHiddenButtonMakesNoImageUntilItShows() throws {
        let window = Self.window()
        let button = SidebarIconButton(icon: .actionClose, label: "Close Workspace")
        button.isHidden = true
        button.frame = NSRect(x: 20, y: 20, width: 20, height: 20)
        let content = try #require(window.contentView)
        content.addSubview(button)
        content.layoutSubtreeIfNeeded()
        #expect(Self.icon(of: button) == nil, "a hidden button made its icon image")
        button.isHidden = false
        let image = try #require(Self.icon(of: button), "a shown button has no icon image")
        #expect(image.isTemplate)
        #expect(image.size.width > 0)
    }

    @Test func aButtonInAHiddenRowMakesNoImageUntilTheRowShows() throws {
        let window = Self.window()
        let row = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 30))
        row.isHidden = true
        let button = SidebarIconButton(icon: .actionClose, label: "Close Workspace")
        button.frame = NSRect(x: 160, y: 5, width: 20, height: 20)
        row.addSubview(button)
        let content = try #require(window.contentView)
        content.addSubview(row)
        content.layoutSubtreeIfNeeded()
        #expect(Self.icon(of: button) == nil, "a button in a hidden row made its icon image")
        row.isHidden = false
        #expect(Self.icon(of: button) != nil, "the button of a shown row has no icon image")
    }

    @Test func aShownButtonHasItsImageInAWindowAndWithoutOne() throws {
        let window = Self.window()
        let shown = SidebarIconButton(icon: .actionClose, label: "Close Workspace")
        try #require(window.contentView).addSubview(shown)
        #expect(Self.icon(of: shown) != nil, "a button shown in a window has no icon image")
        // Sized by its image outside a window too (a stack or constraints read its intrinsic size).
        let loose = SidebarIconButton(icon: .actionClose, label: "Close Workspace")
        #expect(loose.intrinsicContentSize.width > 0)
        #expect(Self.icon(of: loose) != nil)
    }

    @Test func aNewIconOnAHiddenButtonWaitsToo() throws {
        let window = Self.window()
        let button = SidebarIconButton(icon: .disclosureExpanded, label: "Collapse")
        button.isHidden = true
        try #require(window.contentView).addSubview(button)
        button.icon = .disclosureCollapsed
        #expect(Self.icon(of: button) == nil)
        button.isHidden = false
        #expect(Self.icon(of: button) != nil)
    }

    /// Review of #33112 (P3): a workspace row's Unpin button was not hidden at init, so it made its image when the row
    /// joined the window, before the row's first layout hid it. Every hover-only control starts hidden.
    @Test func aNewRowsHoverControlsStartHidden() throws {
        let row = WorkspaceRowView(key: .workspace(WorkspaceID("lazy-controls")))
        for (name, button) in [("close", row.closeButton), ("pin", row.pinButton), ("audio", row.audioButton),
                               ("tree fold", row.treeFoldButton)] {
            #expect(button.isHidden, "a new row's \(name) button starts shown")
            #expect(Self.icon(of: button) == nil, "a new row's \(name) button made its image")
        }
    }
}
