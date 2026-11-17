import AppKit
import CmuxNextActions
@testable import CmuxNextApp
@testable import CmuxNextHome
import Foundation
import Testing

/// Onboarding: the empty Chief conversation's front page offers "Bring your memory from …" when the host found
/// other tools' memory on this Mac, and says nothing when it found none.
@MainActor @Suite struct HomeFirstRunMemoryOfferTests {
    @Test func theImportIsAPaletteActionAndTheCliHasItsOwnVerb() throws {
        let action = try #require(ActionCatalog.all.first { $0.id == "chief.importMemories" })
        #expect(action.surfacePlan.palette.isOffered)
        #expect(action.arguments.map(\.name) == ["chief", "source"])
        #expect(action.arguments.allSatisfy { !$0.isRequired })
        let undo = try #require(ActionCatalog.all.first { $0.id == "chief.importMemories.undo" })
        #expect(undo.surfacePlan.palette.isOffered)
    }
}
