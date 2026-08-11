#if os(iOS)
import SwiftUI
import Testing
import UIKit

@testable import CmuxAgentChatUI

@MainActor
@Suite("Chat keyboard tracking lifecycle", .serialized)
struct ChatKeyboardTrackingLifecycleTests {
    @Test("keyboard did-hide clears a stale overlap")
    func keyboardDidHideClearsStaleOverlap() {
        let controller = ChatKeyboardTrackingViewController(
            transcriptView: Color.clear,
            composerView: Color.clear,
            showsComposer: true
        )
        controller.loadViewIfNeeded()
        controller.keyboardOverlap = 640

        NotificationCenter.default.post(
            name: UIResponder.keyboardDidHideNotification,
            object: nil
        )

        #expect(controller.keyboardOverlap == 0)
    }

    @Test("returning active without composer focus clears a stale overlap")
    func returningActiveWithoutComposerFocusClearsStaleOverlap() {
        let controller = ChatKeyboardTrackingViewController(
            transcriptView: Color.clear,
            composerView: Color.clear,
            showsComposer: true
        )
        controller.loadViewIfNeeded()
        controller.keyboardOverlap = 640

        NotificationCenter.default.post(
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )

        #expect(controller.keyboardOverlap == 0)
    }
}
#endif
