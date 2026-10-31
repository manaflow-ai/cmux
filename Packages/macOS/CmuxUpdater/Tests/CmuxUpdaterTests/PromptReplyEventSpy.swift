import Foundation
@preconcurrency import Sparkle
@testable import CmuxUpdater

/// Records prompt-dismiss lifecycle notifications for prompt identity tests.
@MainActor
final class PromptReplyEventSpy: UpdateDriverEventDelegate {
    func updateDriverNeedsSilentInstallResume() {}
    private(set) var promptDismissalCount = 0

    func updateDriverDidFinishCycle(_ updateCheck: SPUUpdateCheck, error: NSError?) {}
    func updateDriverUserDidCancelCheck() {}
    func updateDriverUserDidDismissPrompt() { promptDismissalCount += 1 }
}
