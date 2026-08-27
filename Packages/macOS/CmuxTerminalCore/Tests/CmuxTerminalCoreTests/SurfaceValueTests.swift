import Foundation
import Testing
import CmuxTerminalCore
import GhosttyKit

@Suite struct NamedKeySendResultTests {
    @Test func acceptedReflectsDelivery() {
        #expect(NamedKeySendResult.sent.accepted)
        #expect(NamedKeySendResult.queued.accepted)
        #expect(!NamedKeySendResult.unknownKey.accepted)
        #expect(!NamedKeySendResult.inputQueueFull.accepted)
        #expect(!NamedKeySendResult.surfaceUnavailable.accepted)
        #expect(!NamedKeySendResult.processExited.accepted)
    }
}

@Suite struct InputSendResultTests {
    @Test func acceptedReflectsDelivery() {
        #expect(InputSendResult.sent.accepted)
        #expect(InputSendResult.queued.accepted)
        #expect(!InputSendResult.inputQueueFull.accepted)
        #expect(!InputSendResult.surfaceUnavailable.accepted)
        #expect(!InputSendResult.processExited.accepted)
    }
}

@Suite struct PendingInputBudgetTests {
    @Test func keyEventCostsAtLeastOneByte() {
        let unlabeled = PendingKeyEvent(keycode: 36, mods: GHOSTTY_MODS_NONE, label: "")
        #expect(unlabeled.queuedByteCost == 1)
        let labeled = PendingKeyEvent(keycode: 36, mods: GHOSTTY_MODS_NONE, label: "enter")
        #expect(labeled.queuedByteCost == 5)
    }

    @Test func estimatedBytesUsesPayloadSize() {
        let data = Data("hello".utf8)
        #expect(PendingSocketInput.pasteText(data).estimatedBytes == 5)
        #expect(PendingSocketInput.inputText(data).estimatedBytes == 5)
        #expect(PendingSocketInput.processOutput(data).estimatedBytes == 5)
        let key = PendingKeyEvent(keycode: 53, mods: GHOSTTY_MODS_NONE, label: "escape")
        #expect(PendingSocketInput.key(key).estimatedBytes == 6)
    }
}

@Suite struct PortalLifecycleStateTests {
    @Test func rawValuesAreStable() {
        #expect(PortalLifecycleState.live.rawValue == "live")
        #expect(PortalLifecycleState.closing.rawValue == "closing")
        #expect(PortalLifecycleState.closed.rawValue == "closed")
    }
}

@Suite struct GhosttyScrollbarTests {
    @Test func capturesRuntimeGeometry() {
        let snapshot = GhosttyScrollbar(
            c: ghostty_action_scrollbar_s(total: 500, offset: 120, len: 40)
        )
        #expect(snapshot.total == 500)
        #expect(snapshot.offset == 120)
        #expect(snapshot.len == 40)
    }

    @Test func capturesExplicitGeometry() {
        let snapshot = GhosttyScrollbar(total: 500, offset: 120, len: 40)

        #expect(snapshot.total == 500)
        #expect(snapshot.offset == 120)
        #expect(snapshot.len == 40)
    }
}
