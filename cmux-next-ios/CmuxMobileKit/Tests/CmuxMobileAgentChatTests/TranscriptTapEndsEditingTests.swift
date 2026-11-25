#if os(iOS)
import SwiftUI
import Testing
import UIKit
@testable import CmuxMobileAgentChat

/// CMUX-34, Safari's bottom bar: a tap on the page while the field is being edited ends
/// the editing and lowers the keyboard. In the agent chat a tap on the transcript did
/// nothing (only a drag dismissed the keyboard), so the person had to swipe to get the
/// keyboard out of the way. Now a tap on the transcript ends editing; the draft stays,
/// and the tap still reaches the row under it.
@MainActor
@Suite(.serialized) struct TranscriptTapEndsEditingTests {
    struct Chat {
        let controller: ChatTranscriptController
        let surface: AgentChatSurface
        let scroll: UIScrollView
        let field: UITextView
        let window: UIWindow
    }

    func chat() throws -> Chat {
        let store = AgentChatStore(source: SmoothChatTests.Silent())
        store.nextFrame = nil
        store.apply(.batch((0..<4).flatMap { SmoothChatTests.turn($0) }))
        let surface = AgentChatSurface()
        let controller = ChatTranscriptController(
            placement: .owned, surface: surface, store: store,
            empty: AnyView(EmptyView()), dock: AnyView(Color.clear.frame(height: 96)), jump: nil
        )
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.layoutIfNeeded()
        let scroll = try #require(controller.view.subviews.lazy.compactMap { $0 as? ChatTranscriptCollectionView }.first)
        // Another text input under the transcript's controller (a row's answer field).
        let field = UITextView(frame: CGRect(x: 0, y: 800, width: 402, height: 40))
        field.text = "a draft in progress"
        controller.view.addSubview(field)
        field.becomeFirstResponder()
        surface.composerFocused = true
        return Chat(controller: controller, surface: surface, scroll: scroll, field: field, window: window)
    }

    @Test func aTapOnTheTranscriptLetsTheComposerGoAndTouchesNothingElse() throws {
        let chat = try chat()
        defer { chat.window.isHidden = true }
        let tap = try #require(chat.scroll.gestureRecognizers?.first { $0 === chat.controller.transcriptTap },
                               "the transcript carries the tap that ends editing")
        #expect(!tap.cancelsTouchesInView, "the tap still reaches the row under it")
        let editing = chat.field.isFirstResponder
        chat.controller.endEditingFromTranscriptTap()
        #expect(!chat.surface.composerFocused, "the composer lets go of focus (its binding lowers the keyboard)")
        // Only the composer's focus: a text input elsewhere (a row's answer field) keeps its own.
        #expect(chat.field.isFirstResponder == editing, "no other editing ends")
        #expect(chat.field.text == "a draft in progress", "the draft stays")
    }

    @Test func aTapWhileReadingMovesNothing() throws {
        let chat = try chat()
        defer { chat.window.isHidden = true }
        chat.surface.composerFocused = false
        chat.controller.endEditingFromTranscriptTap()
        #expect(!chat.surface.composerFocused)
    }
}
#endif
