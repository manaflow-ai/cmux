import CmuxMobileTerminal
import Foundation
import Testing
@testable import CmuxMobileLive

/// File bytes may resume after an outage, but the terminal command must still respect
/// the same hold as typed input, including when no keystrokes were queued.
@MainActor @Suite struct AttachmentSubmissionHoldTests {
    @Test func anOfflineUploadCannotSubmitAfterTheInputHold() async throws {
        let rig = HeldKeysGiveUpTests.Rig()
        defer { rig.session.stop() }
        try await rig.attachedThenDown()
        var expired = 0
        let id = rig.session.beginAttachmentSubmission { expired += 1 }
        rig.session.setMacOffline(true)
        rig.clock += DaemonTerminalSession.inputHoldLimit
        #expect(!rig.session.endAttachmentSubmission(id))
        #expect(expired == 1)
        try await rig.reattach()
        #expect(!rig.session.endAttachmentSubmission(id))
        #expect(rig.typed.isEmpty)
    }

    @Test func aShortReconnectKeepsThePendingSubmission() async throws {
        let rig = HeldKeysGiveUpTests.Rig()
        defer { rig.session.stop() }
        var expired = false
        var id: UUID!
        try await rig.attachedThenDown {
            id = rig.session.beginAttachmentSubmission { expired = true }
            // Time encoding while connected is not time holding input offline.
            rig.clock += 300
        }
        rig.clock += 2
        try await rig.reattach()
        #expect(rig.session.endAttachmentSubmission(id))
        #expect(!expired)
    }

    @Test func suspensionExpiresBeforeTheNextAttachEvenWithoutTypedKeys() async throws {
        let rig = HeldKeysGiveUpTests.Rig()
        defer { rig.session.stop() }
        try await rig.attachedThenDown()
        var expired = false
        let id = rig.session.beginAttachmentSubmission { expired = true }
        rig.clock += DaemonTerminalSession.inputHoldCeiling + 1
        try await rig.reattach()
        #expect(expired)
        #expect(!rig.session.endAttachmentSubmission(id))
    }

    #if os(iOS)
    @Test func projectionForwardsHoldAndDiscardWithoutStoppingTheUpload() async throws {
        let rig = HeldKeysGiveUpTests.Rig()
        defer { rig.session.stop() }
        try await rig.attachedThenDown()
        let projection = TerminalProjectingSession(inner: rig.session)
        var expired = 0
        let id = projection.beginAttachmentSubmission { expired += 1 }
        projection.discardHeldInput()
        #expect(expired == 1)
        #expect(!projection.endAttachmentSubmission(id))
    }

    #endif

    @Test func stoppingTheSessionInvalidatesItsUnsentCommandOnlyOnce() {
        let rig = HeldKeysGiveUpTests.Rig()
        var expired = 0
        let id = rig.session.beginAttachmentSubmission { expired += 1 }
        rig.session.stop()
        rig.session.stop()
        #expect(expired == 1)
        #expect(!rig.session.endAttachmentSubmission(id))
    }

    @Test func reconnectGivingUpExpiresAttachmentSubmissionWithNoTypedKeys() async throws {
        let rig = HeldKeysGiveUpTests.Rig()
        defer { rig.session.stop() }
        var expired = false
        var id: UUID!
        try await rig.attachedThenDown {
            rig.daemon.failNextAttaches = 100
            rig.session.reattachBackoff = [0.02, 0.02]
            id = rig.session.beginAttachmentSubmission { expired = true }
        }
        try await HeldKeysGiveUpTests.waitUntil { expired }
        #expect(expired)
        #expect(!rig.session.endAttachmentSubmission(id))
    }
}
