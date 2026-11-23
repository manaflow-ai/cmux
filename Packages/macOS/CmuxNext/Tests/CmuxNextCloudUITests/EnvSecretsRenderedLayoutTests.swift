#if DEBUG
import AppKit
@testable import CmuxNextCloudUI
import Testing

/// Environment Secrets Playground, checked on the drawn pixels: the playground's AppKit root view draws
/// one direction at the window's size into a bitmap, read back with on-device text recognition. The tests
/// use only the model and the root view, so a layout change shows as a failed reading, not a compile error.
@MainActor @Suite struct EnvSecretsRenderedLayoutTests {
    /// Ledger, History state: the open row's history starts one indent in from the row's left edge.
    /// Before the fix the history was centred under the row, about 255 points to the right.
    @Test func ledgerHistoryStartsAtTheRowsLeftEdge() throws {
        let model = EnvSecretsPlaygroundModel()
        model.scene = .audit
        model.direction = .ledger
        let page = try EnvRenderedPage(model)
        let nameColumn = try #require(page.line("Name"), "the table's Name column title is drawn")
        let firstUse = try #require(page.line(containing: "4:07 PM"), "the history's first line is drawn")
        #expect(firstUse.minX - nameColumn.minX < 40, "history starts \(firstUse.minX - nameColumn.minX) pt right of the Name column")
    }

    /// Sentences, Agent asks state: the request card offers Chat, Personal and Team under "Where to keep
    /// it", Chat is the picked one (the filled accent radio), and the save button says so.
    @Test func sentencesRequestCardOffersTheScopeChoiceWithChatPicked() throws {
        let model = EnvSecretsPlaygroundModel()
        model.scene = .request
        model.direction = .sentences
        let page = try EnvRenderedPage(model)
        #expect(page.line("Where to keep it") != nil, "the card has the \"Where to keep it\" title")
        let chat = try #require(page.line(containing: "Only this chat"), "the Chat choice is drawn")
        let personal = try #require(page.line(containing: "Only you."), "the Personal choice is drawn")
        let team = try #require(page.line(containing: "Needs an admin's Touch ID"), "the Team choice is drawn")
        #expect(page.accentPixels(leftOf: chat) > 0, "the Chat radio is filled")
        #expect(page.accentPixels(leftOf: personal) == 0, "the Personal radio is empty")
        #expect(page.accentPixels(leftOf: team) == 0, "the Team radio is empty")
        #expect(page.line("Save for this chat") != nil, "the save button keeps the value for this chat")
    }
}
#endif
