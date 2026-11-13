import AppKit
@testable import CmuxNextHome
@testable import CmuxNextHomeModel
import Foundation
import Testing

/// The first-run panel in a pane width change (Lawrence 2026-11-11: "when i resize panes ... it doesnt have smooth
/// animation, check all pane types, all must have smooth transition"). In a key resize of the Home each frame gave the
/// panel a new width, and each time it measured every part again (the hero's text, the starters, the Switching card,
/// the stack's fitting size): 22 % of the motion step in a sample of the empty Home, and 14 % in a Home with 500 rows,
/// where the panel is hidden. Its column keeps its width above 388 pt (`maxWidth` + 48 pt), so a wider pane only moves
/// the column; a hidden panel shows nothing.
@MainActor @Suite struct HomeFirstRunWidthChangeTests {
    private static let keys = HomeSwitchKeys(tabByNumber: "⌃1…9", workspaceByNumber: "⌘1…9", nextPreviousTab: "⇧⌘[ ⇧⌘]",
                                             nextPreviousWorkspace: nil, focusBackForward: "⌥⌘, ⌥⌘.")

    /// A panel with a hero face, starters, shortcuts and the Switching card, laid out at `width`.
    private func makePanel(width: CGFloat, height: CGFloat = 800) -> HomeFirstRunView {
        let panel = HomeFirstRunView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        panel.hero.setAvatar(picture: nil, text: nil, name: "Chief")
        panel.setShortcuts(terminal: "⌘T", agent: "⇧⌘N", switching: Self.keys)
        panel.starters.setPrompts(["Fix the failing test in todo-app", "Review sample/todo#42"])
        panel.needsLayout = true
        panel.layoutSubtreeIfNeeded()
        return panel
    }

    /// Where the panel shows each part, in its own coordinates (nil: the part is hidden).
    private func places(_ panel: HomeFirstRunView) -> [CGRect?] {
        ([panel.hero, panel.starters, panel.switchCard] + panel.rows).map { view in
            view.isHiddenOrHasHiddenAncestor ? nil : panel.convert(view.bounds, from: view)
        }
    }

    private func resize(_ panel: HomeFirstRunView, width: CGFloat) {
        panel.setFrameSize(NSSize(width: width, height: panel.frame.height))
        panel.needsLayout = true // as its owner's layout pass gives it one (`HomeNativeTranscriptView.layout`)
        panel.layoutSubtreeIfNeeded()
    }

    @Test func aWidthChangeThatKeepsTheColumnMovesItWithNoMeasure() {
        let panel = makePanel(width: 600)
        #expect(places(panel).allSatisfy { $0 != nil }, "SETUP: every part fits at 600 x 800")
        let before = panel.measurePasses
        for width: CGFloat in [606, 640, 700, 520, 400, 388] {
            resize(panel, width: width)
            #expect(panel.measurePasses == before, "the column is 340 pt at \(width) pt as before: no part is measured again")
            #expect(places(panel) == places(makePanel(width: width)), "each part is where a first layout at \(width) pt puts it")
        }
    }

    @Test func aNarrowerColumnIsMeasuredOnceForEachWidth() {
        let panel = makePanel(width: 600)
        let before = panel.measurePasses
        resize(panel, width: 360)
        #expect(panel.measurePasses == before + 1, "the column goes from 340 to 312 pt: one measure")
        #expect(places(panel) == places(makePanel(width: 360)))
        panel.needsLayout = true
        panel.layoutSubtreeIfNeeded()
        #expect(panel.measurePasses == before + 1, "a layout that changes nothing measures nothing")
    }

    @Test func aHiddenPanelMeasuresNothingAndIsRightWhenItShows() {
        let panel = makePanel(width: 600)
        panel.isHidden = true
        let before = panel.measurePasses
        for width: CGFloat in [380, 360, 340, 320] { resize(panel, width: width) }
        #expect(panel.measurePasses == before, "a hidden panel (a conversation with messages) measures nothing in a resize")
        panel.setMemoryOffer("Bring your memory from Claude Code")
        panel.layoutSubtreeIfNeeded()
        #expect(panel.measurePasses == before, "nor when what it will show changes")
        panel.isHidden = false
        panel.layoutSubtreeIfNeeded()
        #expect(panel.measurePasses == before + 1, "it measures once when it shows again")
        let fresh = makePanel(width: 320)
        fresh.setMemoryOffer("Bring your memory from Claude Code")
        fresh.layoutSubtreeIfNeeded()
        #expect(places(panel) == places(fresh), "and each part is where a first layout at 320 pt puts it")
    }

    @Test func aChangeOfWhatThePanelShowsIsMeasuredAtTheSameWidth() {
        let panel = makePanel(width: 600)
        var passes = panel.measurePasses
        // Each change the panel's owner makes, as `HomeNativeTranscriptView` makes it.
        panel.setShortcuts(terminal: "⌘T", agent: "⇧⌘N", switching: nil)
        panel.layoutSubtreeIfNeeded()
        #expect(panel.measurePasses == passes + 1 && panel.switchCard.isHidden, "the Switching card went")
        passes = panel.measurePasses
        panel.starters.setPrompts(["Fix the failing test in todo-app"])
        panel.needsLayout = true
        panel.layoutSubtreeIfNeeded()
        #expect(panel.measurePasses == passes + 1, "other starters")
        passes = panel.measurePasses
        panel.setIntro("I am your Chief. Tell me what you work on.")
        panel.layoutSubtreeIfNeeded()
        #expect(panel.measurePasses == passes + 1 && !panel.intro.isHidden, "the intro came")
        passes = panel.measurePasses
        panel.applyScale(1.25)
        panel.layoutSubtreeIfNeeded()
        #expect(panel.measurePasses == passes + 1, "a new interface scale")
        passes = panel.measurePasses
        panel.setFrameSize(NSSize(width: 600, height: 500))
        panel.needsLayout = true
        panel.layoutSubtreeIfNeeded()
        #expect(panel.measurePasses == passes + 1, "a new height changes what fits")
        let fresh = HomeFirstRunView(frame: NSRect(x: 0, y: 0, width: 600, height: 500))
        fresh.hero.setAvatar(picture: nil, text: nil, name: "Chief")
        fresh.applyScale(1.25)
        fresh.setShortcuts(terminal: "⌘T", agent: "⇧⌘N", switching: nil)
        fresh.starters.setPrompts(["Fix the failing test in todo-app"])
        fresh.setIntro("I am your Chief. Tell me what you work on.")
        fresh.needsLayout = true
        fresh.layoutSubtreeIfNeeded()
        #expect(places(panel) == places(fresh), "each part is where a first layout of the same content puts it")
    }
}
