#if canImport(UIKit)
import Foundation
import Testing
import UIKit
@testable import CmuxConversationCore
@testable import CmuxConversationUI
@testable import CmuxMobileChief

/// CMUX-25: Chief's back button stays in the same place whatever Chief
/// pins at the top. The question bar and the waiting-to-send list used to
/// sit above the header and push the whole header, back button included,
/// about 70 pt down, so a tap where back always is missed it.
@MainActor
@Suite struct ChiefBackButtonPlacementTests {
    private func shown(_ session: ChiefSession) -> (ChiefConversationContainer, UIWindow) {
        let conversation = ConversationViewController(store: session.store, options: .chief)
        let container = ChiefConversationContainer(conversation: conversation, session: session)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = container
        window.isHidden = false
        container.beginAppearanceTransition(true, animated: false)
        container.endAppearanceTransition()
        container.view.layoutIfNeeded()
        return (container, window)
    }

    private func backFrame(_ container: ChiefConversationContainer) -> CGRect {
        let back = container.conversation.header.backButton
        return back.convert(back.bounds, to: container.view)
    }

    @Test(.timeLimit(.minutes(1))) func backStaysPutWhileMessagesWaitToSend() throws {
        let plain = ChiefSession(backend: ChiefOfflineBackend(), outbox: ChiefOutbox(file: nil))
        let waiting = ChiefSession(backend: ChiefOfflineBackend(), outbox: ChiefOutbox(file: nil))
        waiting.send(ConversationComposeMessage(text: "Check the latest build."), asksForAlerts: false)
        try #require(!waiting.outbox.isEmpty)
        let (rest, restWindow) = shown(plain)
        let (pinned, pinnedWindow) = shown(waiting)
        defer {
            plain.store.stop(); waiting.store.stop()
            ConversationThemeOwners.disappeared(rest.conversation)
            ConversationThemeOwners.disappeared(pinned.conversation)
            restWindow.isHidden = true; pinnedWindow.isHidden = true
        }
        pinned.view.setNeedsLayout()
        pinned.view.layoutIfNeeded()
        let bar = pinned.questionBar.view.frame
        try #require(bar.height > 0)

        // The back button is exactly where it is with nothing pinned.
        #expect(backFrame(pinned) == backFrame(rest))
        #expect(pinned.conversation.additionalSafeAreaInsets.top == 0)
        // The bar is under the header, never over the back button.
        let headerBottom = pinned.conversation.view.convert(CGPoint(x: 0, y: pinned.conversation.header.frame.maxY), to: pinned.view).y
        // Offline: the header's "Connecting…" line shows, and the bar sits below it.
        let status = pinned.conversation.header.statusLabel
        if status.text != nil {
            #expect(bar.minY >= status.convert(status.bounds, to: pinned.view).maxY)
        }
        #expect(bar.minY >= headerBottom)
        #expect(!bar.intersects(backFrame(pinned)))
        // The transcript starts below the bar, so no bubble is under it (R2-1).
        let transcriptTop = pinned.conversation.collectionView.contentInset.top
        #expect(transcriptTop >= bar.maxY)
        #expect(transcriptTop > rest.conversation.collectionView.contentInset.top)
        // A full composer field and the reply thread stop under the bar too.
        #expect(pinned.conversation.contentTop >= bar.maxY)
        #expect(pinned.conversation.composer.maximumFieldHeight < rest.conversation.composer.maximumFieldHeight)
    }
}
#endif
