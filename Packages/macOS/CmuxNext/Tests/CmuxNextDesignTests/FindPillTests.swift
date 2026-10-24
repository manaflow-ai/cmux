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
