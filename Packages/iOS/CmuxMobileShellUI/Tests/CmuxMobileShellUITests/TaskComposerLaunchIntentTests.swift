#if os(iOS)
import CmuxMobileShellModel
import Foundation
import Testing
@testable import CmuxMobileShellUI

@Suite struct TaskComposerLaunchIntentTests {
    private static func savedDraft(prompt: String, at seconds: Double) -> MobileTaskComposerSavedDraft {
        MobileTaskComposerSavedDraft(
            updatedAt: Date(timeIntervalSince1970: seconds),
            content: MobileTaskComposerDraft(
                prompt: prompt,
                templateID: nil,
                macDeviceID: "mac-a",
                directory: "~",
                didEditDirectory: false
            )
        )
    }

    @Test func automaticResumesTheNewestDraftAndFallsBackToFresh() {
        let newest = Self.savedDraft(prompt: "Newest", at: 200)
        let older = Self.savedDraft(prompt: "Older", at: 100)

        #expect(TaskComposerLaunchIntent.automatic.resolveDraft(in: [newest, older]) == newest)
        #expect(TaskComposerLaunchIntent.automatic.resolveDraft(in: []) == nil)
    }

    @Test func resumeSelectsExactlyTheRequestedDraft() {
        let newest = Self.savedDraft(prompt: "Newest", at: 200)
        let older = Self.savedDraft(prompt: "Older", at: 100)

        #expect(TaskComposerLaunchIntent.resume(older.id).resolveDraft(in: [newest, older]) == older)
    }

    @Test func resumeOfADeletedDraftStartsFreshInsteadOfStealingAnother() {
        let newest = Self.savedDraft(prompt: "Newest", at: 200)

        #expect(TaskComposerLaunchIntent.resume(UUID()).resolveDraft(in: [newest]) == nil)
    }

    @Test func newIgnoresSavedDrafts() {
        let newest = Self.savedDraft(prompt: "Newest", at: 200)

        #expect(TaskComposerLaunchIntent.new.resolveDraft(in: [newest]) == nil)
    }

    @Test func switchingAlwaysChangesSessionIdentity() {
        let first = TaskComposerLaunch()
        let second = first.switching(to: .new)
        let third = second.switching(to: .automatic)

        #expect(second.token != first.token)
        #expect(third.token != second.token)
        #expect(third.intent == .automatic)
        #expect(third != first)
    }
}
#endif
