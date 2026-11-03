@testable import CmuxNextActions
import Testing

/// Move Sessions from Another cmux Build… (cx-yxmkh): the palette's way into
/// `SessionTransferService`. A person picks the sessions in a dialog, so the
/// CLI and the socket never run it (scripts use `session.transfer.pull`).
@MainActor
@Suite struct SessionMoveFromBuildActionTests {
    @Test func thePaletteOffersMoveSessionsFromAnotherBuild() throws {
        let action = try #require(ActionCatalog.all.first { $0.id == "session.moveFromBuild" },
                                  "the catalog has no session.moveFromBuild")
        #expect(action.title == "Move Sessions from Another cmux Build…")
        #expect(action.surfacePlan.palette.isOffered)
        #expect(action.surfacePlan.cli == .exempt(.guiOnly))
        #expect(action.surfacePlan.contextMenuExemption == .noObject)
        #expect(action.surfacePlan.mcpExemption == nil)
        #expect(action.isPersonOnly)
        #expect(action.waitsForResult)
        for word in ["move", "transfer", "import", "dev", "nightly", "build", "session"] {
            #expect(action.keywords.contains(word), "keyword \(word)")
        }
    }
}
