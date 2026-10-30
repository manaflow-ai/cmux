import AppKit
@testable import CmuxNextDesign
import Testing
import CmuxNextDesignTokens

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
}
