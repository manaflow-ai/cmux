import AppKit
@testable import CmuxNextBookmarks
import CmuxNextIcons
import CmuxNextInput
@testable import CmuxNextSidebar
import CmuxNextTabs
import Testing

/// Event identity in the bookmarks, sidebar and tab strip (DC7): each reads the event
/// it acts on from the input tap (the dispatched record, or the event a menu's loop took), never
/// AppKit's current event, so a run between dispatches does not reuse the last click's modifiers.
@MainActor @Suite(.serialized) struct EventIdentityTests {
    // MARK: Bookmark folder menu

    @Test func aModifiedClickInTheFolderMenuOpensByItsModifiers() throws {
        let tap = InputEventTap()
        Self.dispatch(try Self.mouse(.leftMouseDown, at: 1), through: tap) // the click that opened the menu
        let commandUp = try Self.mouse(.leftMouseUp, at: 2, modifiers: .command)
        let shiftUp = try Self.mouse(.leftMouseUp, at: 2, modifiers: .shift)
        let optionUp = try Self.mouse(.leftMouseUp, at: 2, modifiers: .option)
        #expect(BookmarkFolderMenu.disposition(of: tap.trackedEvent(current: commandUp)) == .backgroundTab)
        #expect(BookmarkFolderMenu.disposition(of: tap.trackedEvent(current: shiftUp)) == .newTab)
        #expect(BookmarkFolderMenu.disposition(of: tap.trackedEvent(current: optionUp)) == .currentTab)
    }

    @Test func aMenuItemChosenWithNoNewEventIgnoresTheLastClicksModifiers() throws {
        let tap = InputEventTap()
        let commandClick = try Self.mouse(.leftMouseDown, at: 1, modifiers: .command)
        Self.dispatch(commandClick, through: tap)
        // VoiceOver or a script picks the item: AppKit's current event is still the Cmd-click.
        #expect(BookmarkFolderMenu.disposition(of: tap.trackedEvent(current: commandClick)) == .currentTab)
    }

    // MARK: Sidebar group editor

    @Test func theGroupEditorTogglesClosedOnlyForThePressThatClosedIt() throws {
        let editor = SidebarGroupEditor()
        let group = GroupID("grp_identity")
        let press = InputEventRecord(type: .leftMouseDown, timestamp: 10)
        editor.lastInput = { press }
        editor.noteClosed(group)
        #expect(editor.closedByThisClick(group, input: press), "the press that closed the editor reopened it")
        #expect(!editor.closedByThisClick(group, input: InputEventRecord(type: .leftMouseDown, timestamp: 10.05)),
                "a fast second click did not reopen it (cx-q5jw)")
        #expect(!editor.closedByThisClick(GroupID("grp_other"), input: press), "another group's editor matched")
        #expect(!editor.closedByThisClick(group, input: nil), "a run with no input matched")
    }

    @Test func aCloseOutsideAPressFallsBackToTheDoubleClickTime() {
        let editor = SidebarGroupEditor()
        let group = GroupID("grp_escape")
        editor.lastInput = { InputEventRecord(type: .keyDown, timestamp: 20) }
        editor.noteClosed(group)
        #expect(editor.closedByThisClick(group, input: InputEventRecord(type: .leftMouseDown, timestamp: 20.01)))
        #expect(!editor.closedByThisClick(group, input: InputEventRecord(type: .leftMouseDown,
                                                                          timestamp: 20 + NSEvent.doubleClickInterval + 1)))
    }

    // MARK: Tab strip

    @Test func theTabStripTakesTheKeyboardFromAKeyButNotFromAPress() throws {
        let tap = InputEventTap()
        let strip = TabStripView(model: TabStripModel(tabs: []), input: tap)
        Self.dispatch(try Self.mouse(.leftMouseDown, at: 1), through: tap)
        #expect(!strip.acceptsFirstResponder, "a click in the strip took the keyboard")
        Self.dispatch(try Self.key(at: 2), through: tap)
        #expect(strip.acceptsFirstResponder, "the key view loop could not reach the strip")
    }

    // MARK: Sidebar card buttons

    /// A card's x takes the keyboard from Tab, never from a click (Option-click included): the card
    /// hides after the click, and the focus must not stay on a hidden button. The tap is found
    /// through the button's window.
    @Test func aSidebarIconButtonTakesTheKeyboardFromTabButNotFromAnOptionClick() throws {
        let tap = InputEventTap()
        let button = SidebarIconButton(icon: .actionAdd, label: "Close")
        button.takesKeyFocus = true
        button.fullKeyboardAccess = { true }
        let window = Self.window(holding: button, tap: tap)
        defer { window.contentView = nil }
        Self.dispatch(try Self.mouse(.leftMouseDown, at: 1, modifiers: .option), through: tap)
        #expect(!button.acceptsFirstResponder, "an Option-click left the keyboard on the card's x")
        Self.dispatch(try Self.key(at: 2), through: tap)
        #expect(button.acceptsFirstResponder, "Tab could not reach the card's x")
        button.fullKeyboardAccess = { false }
        #expect(!button.acceptsFirstResponder, "Tab reached it with Full Keyboard Access off")
    }

    @Test func aSidebarCardTextButtonTakesTheKeyboardFromTabButNotFromAnOptionClick() throws {
        let tap = InputEventTap()
        let button = SidebarCardTextButton()
        button.fullKeyboardAccess = { true }
        let window = Self.window(holding: button, tap: tap)
        defer { window.contentView = nil }
        Self.dispatch(try Self.mouse(.leftMouseDown, at: 1, modifiers: .option), through: tap)
        #expect(!button.acceptsFirstResponder, "an Option-click left the keyboard on the card's Hide")
        Self.dispatch(try Self.key(at: 2), through: tap)
        #expect(button.acceptsFirstResponder, "Tab could not reach the card's Hide")
        button.fullKeyboardAccess = { false }
        #expect(!button.acceptsFirstResponder, "Tab reached it with Full Keyboard Access off")
    }

    // MARK: Events

    /// A window that carries `tap`, as the App's windows do, holding `view`.
    private static func window(holding view: NSView, tap: InputEventTap) -> TapWindow {
        let window = TapWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 80), styleMask: [.titled],
                               backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.inputTap = tap
        view.frame = NSRect(x: 10, y: 10, width: 40, height: 20)
        window.contentView?.addSubview(view)
        return window
    }

    private final class TapWindow: NSWindow, InputTapHosting {
        var inputTap: InputEventTap?
    }

    private static func dispatch(_ event: NSEvent, through tap: InputEventTap) {
        tap.dispatching {
            tap.deliverObserve(event)
            _ = tap.deliverIntercepts(event)
            tap.deliverAfterDispatch(event)
        }
    }

    private static func mouse(_ type: NSEvent.EventType, at timestamp: TimeInterval,
                              modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
        _ = NSApplication.shared
        return try #require(NSEvent.mouseEvent(with: type, location: .zero, modifierFlags: modifiers, timestamp: timestamp,
                                               windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    }

    private static func key(at timestamp: TimeInterval) throws -> NSEvent {
        _ = NSApplication.shared
        return try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: timestamp,
                                             windowNumber: 0, context: nil, characters: "\t",
                                             charactersIgnoringModifiers: "\t", isARepeat: false, keyCode: 48))
    }
}
