import Foundation
import Testing
@testable import CmuxMobileShell

@MainActor
@Test("replacing an output consumer preserves the replay watchdog deadline")
func replacingOutputConsumerPreservesReplayWatchdogDeadline() throws {
    let store = MobileShellComposite.preview()
    let surfaceID = "watchdog-surface"
    let barrierToken = UUID()
    store.terminalReplayBarrierTokensBySurfaceID[surfaceID] = barrierToken

    let firstStream = store.terminalOutputStream(surfaceID: surfaceID)
    let firstWatchdogID = try #require(
        store.terminalReplayBarrierWatchdogIDsBySurfaceID[surfaceID]
    )
    #expect(
        store.terminalReplayBarrierWatchdogTokensBySurfaceID[surfaceID] == barrierToken
    )

    let replacementStream = store.terminalOutputStream(surfaceID: surfaceID)
    _ = (firstStream, replacementStream)
    #expect(
        store.terminalReplayBarrierWatchdogIDsBySurfaceID[surfaceID] == firstWatchdogID
    )
}
