import AppKit
@testable import CmuxNextDesign
import Testing
import CmuxNextDesignTokens
import CmuxNextInput

/// Lawrence, 2026-10-20: every Cmd-F bar (terminal, browser, Agent chat, diff viewer) is one
/// Liquid Glass capsule that looks and behaves the same (plans/cmux-next/find-pill-gallery.html,
/// variant A). These tests drive the one shared native pill through its public seams.
@MainActor @Suite struct FindPillTests {
    private func makePill(matchCase: Bool = false) -> FindPillView {
        let image = NSImage(size: NSSize(width: 12, height: 12))
        let icons = FindPillIcons(search: image, previous: image, next: image, close: image)
        let labels = FindPillLabels(placeholder: "Find", previous: "Previous Match", next: "Next Match",
                                    close: "Close", matchCase: matchCase ? "Match Case" : nil)
        return FindPillView(labels: labels, icons: icons, accessibilityPrefix: "test.find")
    }

    @Test func thePillIsACapsuleOfTheSharedHeight() {
        let pill = makePill()
        pill.frame = NSRect(origin: .zero, size: pill.fittingSize)
        pill.layoutSubtreeIfNeeded()
        #expect(pill.fittingSize.height == FindPillMetrics.height)
        #expect(pill.surface.cornerRadius == FindPillMetrics.height / 2)
    }

    @Test func findArrowEditingIsForwardedToTheFieldEditor() {
        #expect(FindPillView.shouldForwardArrowKeyDown(keyCode: 123, flags: [], hasMarkedText: false))
        #expect(FindPillView.shouldForwardArrowKeyDown(keyCode: 124, flags: [.shift], hasMarkedText: false))
        #expect(FindPillView.shouldForwardArrowKeyDown(keyCode: 125, flags: [.option, .shift], hasMarkedText: false))
        #expect(FindPillView.shouldForwardArrowKeyDown(keyCode: 126, flags: [.command, .shift], hasMarkedText: false))
        #expect(!FindPillView.shouldForwardArrowKeyDown(keyCode: 122, flags: [], hasMarkedText: false))
        #expect(!FindPillView.shouldForwardArrowKeyDown(keyCode: 123, flags: [.control], hasMarkedText: false))
        #expect(!FindPillView.shouldForwardArrowKeyDown(keyCode: 123, flags: [], hasMarkedText: true))
    }

    @Test func forwardingFindArrowMovesTheFieldEditorCaret() throws {
        let pill = makePill()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 80), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.orderOut(nil); window.contentView = nil }
        let root = try #require(window.contentView)
        pill.frame = NSRect(x: 20, y: 20, width: 320, height: FindPillMetrics.height)
        pill.isHidden = false
        root.addSubview(pill)
        pill.query = "abcd"
        #expect(window.makeFirstResponder(pill.field))
        let editor = try #require(pill.field.currentEditor() as? NSTextView)
        editor.setSelectedRange(NSRange(location: 4, length: 0))

        let leftCharacter = String(Character(UnicodeScalar(NSLeftArrowFunctionKey)!))
        let left = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                 windowNumber: window.windowNumber, context: nil,
                                                 characters: leftCharacter, charactersIgnoringModifiers: leftCharacter,
                                                 isARepeat: false, keyCode: 123))
        #expect(FindPillView.forwardArrowKeyDown(left, in: window))
        #expect(editor.selectedRange == NSRange(location: 3, length: 0))

        let rightCharacter = String(Character(UnicodeScalar(NSRightArrowFunctionKey)!))
        let right = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                  windowNumber: window.windowNumber, context: nil,
                                                  characters: rightCharacter, charactersIgnoringModifiers: rightCharacter,
                                                  isARepeat: false, keyCode: 124))
        #expect(FindPillView.forwardArrowKeyDown(right, in: window))
        #expect(editor.selectedRange == NSRange(location: 4, length: 0))

        let ordinary = NSTextField(frame: NSRect(x: 20, y: 0, width: 320, height: 20))
        root.addSubview(ordinary)
        #expect(window.makeFirstResponder(ordinary))
        #expect(!FindPillView.forwardArrowKeyDown(left, in: window), "unrelated field editors stay on AppKit's normal path")
    }

    @Test func returnStepsForwardShiftReturnStepsBackEscapeCloses() {
        let pill = makePill()
        var commands: [FindPillCommand] = []
        pill.onCommand = { commands.append($0) }
        #expect(pill.handleFieldCommand(#selector(NSResponder.insertNewline(_:)), shift: false))
        #expect(pill.handleFieldCommand(#selector(NSResponder.insertNewline(_:)), shift: true))
        #expect(pill.handleFieldCommand(#selector(NSResponder.cancelOperation(_:)), shift: false))
        #expect(!pill.handleFieldCommand(#selector(NSResponder.moveLeft(_:)), shift: false))
        #expect(commands == [.next, .previous, .close])
    }

    @Test func typingReportsTheQueryAndSettingItDoesNot() {
        let pill = makePill()
        var reported: [String] = []
        pill.onQueryChange = { reported.append($0) }
        pill.query = "seeded"
        #expect(reported.isEmpty)
        pill.simulateTyping("error")
        #expect(reported == ["error"])
        #expect(pill.query == "error")
    }

    @Test func theMatchCaseToggleShowsOnlyWhereTheSurfaceSupportsIt() throws {
        #expect(makePill(matchCase: false).matchCaseButton == nil)
        let pill = makePill(matchCase: true)
        var changes: [Bool] = []
        pill.onMatchCaseChange = { changes.append($0) }
        let toggle = try #require(pill.matchCaseButton)
        toggle.performClick(nil)
        toggle.performClick(nil)
        #expect(changes == [true, false])
        #expect(pill.matchCase == false)
    }

    @Test func theCountReadsAsAnAnswerWhenNothingMatches() {
        let pill = makePill()
        pill.showCount("2 of 3", noMatches: false)
        #expect(pill.countText == "2 of 3")
        #expect(!pill.showsNoMatches)
        pill.showCount("No matches", noMatches: true)
        #expect(pill.showsNoMatches)
    }

    @Test func stepButtonsAreDisabledWithoutMatches() {
        let pill = makePill()
        pill.showCount("", noMatches: false, canStep: false)
        #expect(pill.stepButtons.allSatisfy { !$0.isEnabled })
        pill.showCount("1 of 4", noMatches: false, canStep: true)
        #expect(pill.stepButtons.allSatisfy { $0.isEnabled })
    }

    // MARK: Per-key cost

    /// A key that is not an arrow returns before it reads the window's first responder, so a
    /// plain key does no find pill work.
    @Test func aKeyThatIsNotAnArrowNeverReadsTheFirstResponder() throws {
        let window = CountingWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 80), styleMask: [.titled],
                                    backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.orderOut(nil) }
        let plainKeys = try [("a", UInt16(0)), ("\r", 36), (" ", 49), ("\u{1b}", 53)].map { characters, keyCode in
            try Self.keyDown(characters, keyCode: keyCode, window: window)
        }
        let left = try Self.keyDown(String(Character(UnicodeScalar(NSLeftArrowFunctionKey)!)), keyCode: 123, window: window)
        window.firstResponderReads = 0  // count only the calls under test, not AppKit's setup reads
        for event in plainKeys {
            #expect(!FindPillView.forwardArrowKeyDown(event, in: window))
        }
        #expect(window.firstResponderReads == 0, "a plain key read the first responder")
        #expect(!FindPillView.forwardArrowKeyDown(left, in: window))
        #expect(window.firstResponderReads == 1, "an arrow asks the window who has the keyboard")
        #expect((123...126).allSatisfy { FindPillView.isArrowKeyCode($0) })
        #expect(![UInt16(0), 36, 49, 53, 115, 122, 127].contains(where: FindPillView.isArrowKeyCode))
    }

    /// The app's key-down stage (`CmuxApplication.sendEvent`): in a window that carries the tap, a
    /// plain key, and an arrow while no pill edits, read no responder; an arrow while a pill edits
    /// reaches the pill's field editor.
    @Test func theAppStageAsksNoResponderUnlessAnArrowMeetsAnEditingPill() throws {
        let tap = InputEventTap(), pill = makePill()
        let window = CountingWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 80), styleMask: [.titled],
                                    backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.inputTap = tap
        defer { window.orderOut(nil); window.contentView = nil }
        let root = try #require(window.contentView)
        pill.frame = NSRect(x: 20, y: 20, width: 320, height: FindPillMetrics.height)
        pill.isHidden = false
        root.addSubview(pill)
        pill.query = "abcd"
        let plain = try Self.keyDown("a", keyCode: 0, window: window)
        let left = try Self.keyDown(String(Character(UnicodeScalar(NSLeftArrowFunctionKey)!)), keyCode: 123, window: window)
        window.firstResponderReads = 0  // count only the calls under test, not AppKit's setup reads
        let plainWithNoPill = FindPillView.forwardArrowKeyDownToEditingPill(plain, in: window)
        let arrowWithNoPill = FindPillView.forwardArrowKeyDownToEditingPill(left, in: window)
        #expect(!plainWithNoPill && !arrowWithNoPill)
        #expect(window.firstResponderReads == 0, "a key with no pill editing read the first responder")

        #expect(window.makeFirstResponder(pill.field))
        let editor = try #require(pill.field.currentEditor() as? NSTextView)
        editor.setSelectedRange(NSRange(location: 4, length: 0))
        window.firstResponderReads = 0
        #expect(!FindPillView.forwardArrowKeyDownToEditingPill(plain, in: window))
        #expect(window.firstResponderReads == 0, "a plain key read the first responder while a pill edits")
        #expect(FindPillView.forwardArrowKeyDownToEditingPill(left, in: window))
        #expect(editor.selectedRange == NSRange(location: 3, length: 0))
    }

    /// A pill holds its window's input tap `findPillOpen` flag while its field has the keyboard, so
    /// the app's key-down asks no responder while no pill edits. Pills in two windows (each with its
    /// own first responder) hold it together: it clears when the last edit ends.
    @Test func editingPillsHoldTheirWindowsTapFindPillFlag() throws {
        let tap = InputEventTap()
        let (first, firstWindow) = try makeWindowedPill(tap: tap)
        let (second, secondWindow) = try makeWindowedPill(tap: tap)
        defer { [firstWindow, secondWindow].forEach { $0.orderOut(nil); $0.contentView = nil } }
        #expect(!tap.flags.contains(.findPillOpen))

        #expect(firstWindow.makeFirstResponder(first.field))
        #expect(first.fieldHasKeyboard && tap.flags.contains(.findPillOpen))
        #expect(secondWindow.makeFirstResponder(second.field))  // another window's own first responder
        #expect(firstWindow.makeFirstResponder(nil))
        #expect(!first.fieldHasKeyboard)
        #expect(tap.flags.contains(.findPillOpen), "a pill still edits in the other window")
        second.removeFromSuperview()  // a closed tab: its edit is over
        #expect(!second.fieldHasKeyboard)
        #expect(!tap.flags.contains(.findPillOpen), "no pill edits, the flag stayed")
    }

    /// Shift-Return in the field goes to the previous match: its Shift comes from the key the window's
    /// tap dispatched, not from AppKit's current event, which a run after the key keeps.
    @Test func shiftReturnInTheFieldReadsShiftFromTheDispatchedKey() throws {
        let tap = InputEventTap()
        let (pill, window) = try makeWindowedPill(tap: tap)
        defer { window.orderOut(nil); window.contentView = nil }
        var commands: [FindPillCommand] = []
        pill.onCommand = { commands.append($0) }
        #expect(window.makeFirstResponder(pill.field))
        let editor = try #require(pill.field.currentEditor() as? NSTextView)
        let newline = #selector(NSResponder.insertNewline(_:))

        Self.dispatch(try Self.returnKey(.shift, at: 1, window: window), through: tap)
        #expect(pill.control(pill.field, textView: editor, doCommandBy: newline))
        Self.dispatch(try Self.returnKey([], at: 2, window: window), through: tap)
        #expect(pill.control(pill.field, textView: editor, doCommandBy: newline))
        #expect(commands == [.previous, .next], "Return's Shift did not come from the dispatched key")
    }

    private static func dispatch(_ event: NSEvent, through tap: InputEventTap) {
        tap.dispatching {
            tap.deliverObserve(event)
            _ = tap.deliverIntercepts(event)
            tap.deliverAfterDispatch(event)
        }
    }

    private static func returnKey(_ modifiers: NSEvent.ModifierFlags, at timestamp: TimeInterval, window: NSWindow) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: timestamp,
                                      windowNumber: window.windowNumber, context: nil, characters: "\r",
                                      charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
    }

    private func makeWindowedPill(tap: InputEventTap) throws -> (FindPillView, NSWindow) {
        let pill = makePill()
        let window = TapWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 80), styleMask: [.titled],
                               backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.inputTap = tap
        let root = try #require(window.contentView)
        pill.frame = NSRect(x: 20, y: 20, width: 320, height: FindPillMetrics.height)
        pill.isHidden = false
        root.addSubview(pill)
        return (pill, window)
    }

    private static func keyDown(_ characters: String, keyCode: UInt16, window: NSWindow) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                      windowNumber: window.windowNumber, context: nil, characters: characters,
                                      charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode))
    }

    /// Counts reads of its first responder; carries a tap when one is given.
    private final class CountingWindow: NSWindow, InputTapHosting {
        var inputTap: InputEventTap?
        var firstResponderReads = 0
        override var firstResponder: NSResponder? {
            firstResponderReads += 1
            return super.firstResponder
        }
    }

    /// A window that carries the app's tap, as the App's main windows do.
    private final class TapWindow: NSWindow, InputTapHosting {
        var inputTap: InputEventTap?
    }
}
