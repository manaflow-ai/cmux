import AppKit
import CmuxNextActions
@testable import CmuxNextApp
@testable import CmuxNextHome
import Foundation
import Testing

/// Onboarding: the empty Chief conversation's front page offers "Bring your memory from …" when the host found
/// other tools' memory on this Mac, and says nothing when it found none.
@MainActor @Suite struct HomeFirstRunMemoryOfferTests {
    @Test func theRowIsAbsentUntilTheHostOffersIt() {
        let panel = HomeFirstRunView(frame: NSRect(x: 0, y: 0, width: 400, height: 700))
        #expect(!panel.actionRows.contains { $0 === panel.memory })
        panel.setMemoryOffer("Bring your memory from Claude Code and ChatGPT")
        #expect(panel.actionRows.contains { $0 === panel.memory })
        #expect(panel.memory.title == "Bring your memory from Claude Code and ChatGPT")
        #expect(panel.memory.accessibilityLabel() == "Bring your memory from Claude Code and ChatGPT")
        panel.setMemoryOffer(nil)
        #expect(!panel.actionRows.contains { $0 === panel.memory })
    }

    @Test func clickingTheRowAsksForTheImport() {
        let panel = HomeFirstRunView(frame: NSRect(x: 0, y: 0, width: 400, height: 700))
        var asked: [HomeFirstRunAction] = []
        panel.onAction = { asked.append($0) }
        panel.setMemoryOffer("Bring your memory from Codex")
        panel.memory.performClick(nil)
        #expect(asked == [.importMemories])
    }

    @Test func theRowSitsBeforeThePetRowAndNoTextCountsSteps() throws {
        let panel = HomeFirstRunView(frame: NSRect(x: 0, y: 0, width: 400, height: 700))
        panel.setMemoryOffer("Bring your memory from Codex")
        let order = panel.actionRows
        let memory = try #require(order.firstIndex { $0 === panel.memory })
        let pet = try #require(order.firstIndex { $0 === panel.pet })
        #expect(memory < pet)
        #expect(panel.memory.title.range(of: #"\b\d+\s+steps?\b"#, options: [.regularExpression, .caseInsensitive]) == nil)
    }

    @Test func theImportIsAPaletteActionAndTheCliHasItsOwnVerb() throws {
        let action = try #require(ActionCatalog.all.first { $0.id == "chief.importMemories" })
        #expect(action.surfacePlan.palette.isOffered)
        #expect(action.arguments.map(\.name) == ["chief", "source"])
        #expect(action.arguments.allSatisfy { !$0.isRequired })
        let undo = try #require(ActionCatalog.all.first { $0.id == "chief.importMemories.undo" })
        #expect(undo.surfacePlan.palette.isOffered)
    }
}
