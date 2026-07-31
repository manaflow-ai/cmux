import Foundation
@preconcurrency import Sparkle
@testable import CmuxUpdater

/// Records prompt-dismiss lifecycle notifications for prompt identity tests.
@MainActor
final class PromptReplyEventSpy: UpdateDriverEventDelegate {
    private(set) var promptDismissalCount = 0

    func updateDriverDidFinishCycle(_ updateCheck: SPUUpdateCheck, error: NSError?) {}
    func updateDriverWillPresentNoUpdate() {}
    func updateDriverDidPresentError() {}
    func updateDriverRequestsRetryAfterError() {}
    func updateDriverDidDismissError() {}
    func updateDriverUserDidCancelCheck() {}
    func updateDriverUserDidDismissPrompt() { promptDismissalCount += 1 }
}
