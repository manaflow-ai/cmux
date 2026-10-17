import Foundation
import Testing
@testable import CmuxBrowser

/// The save-password question in the prompt strip (design spec §8b): its own
/// buttons, never merged with another offer, and not ended by navigation.
@Suite("Save-password prompt") @MainActor
struct BrowserPasswordSavePromptTests {
    private let site = URL(string: "http://localhost:19250/login")!

    @Test func saveAndUpdateOffersHaveTheirOwnButtons() {
        let save = BrowserPermissionPrompt.savePassword(origin: site, username: "fixture-user", isUpdate: false)
        #expect(save.isPasswordPrompt)
        #expect(save.style == .savePassword(isUpdate: false))
        #expect(save.displayOrigin == "localhost:19250")
        let update = BrowserPermissionPrompt.savePassword(origin: site, username: "", isUpdate: true)
        #expect(update.style == .savePassword(isUpdate: true))
        #expect(!BrowserPermissionPrompt(kinds: [.camera], origin: site).isPasswordPrompt)
    }

    @Test func navigationEndsPermissionQuestionsButNotPasswordOffers() {
        let queue = BrowserPermissionPromptQueue()
        var ended: [String] = []
        queue.enqueue(BrowserPermissionPrompt(kinds: [.camera], origin: site)) { ended.append("camera=\($0.map { "\($0)" } ?? "none")") }
        let offer = BrowserPermissionPrompt.savePassword(origin: site, username: "fixture-user", isUpdate: false)
        queue.enqueue(offer) { ended.append("password=\($0.map { "\($0)" } ?? "none")") }

        queue.cancelPermissionPrompts()
        #expect(ended == ["camera=none"])
        #expect(queue.current?.id == offer.id)

        queue.answer(offer.id, with: .allowAndRemember)
        #expect(ended == ["camera=none", "password=allowAndRemember"])
        #expect(queue.current == nil)
    }

    @Test func twoOffersForOneSignInStayTwoQuestions() {
        let queue = BrowserPermissionPromptQueue()
        queue.enqueue(.savePassword(origin: site, username: "fixture-user", isUpdate: false)) { _ in }
        queue.enqueue(.savePassword(origin: site, username: "fixture-user", isUpdate: false)) { _ in }
        #expect(queue.prompts.count == 2)
        queue.cancelAll()
        #expect(queue.prompts.isEmpty)
    }
}
