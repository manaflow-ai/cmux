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
        // A stand-in for the composer's field, holding first responder as the field does.
        let field = UITextView(frame: CGRect(x: 0, y: 800, width: 402, height: 40))
        field.text = "a draft in progress"
        controller.view.addSubview(field)
        field.becomeFirstResponder()
        surface.composerFocused = true
        return Chat(controller: controller, surface: surface, scroll: scroll, field: field, window: window)
    }

    @Test func aTapOnTheTranscriptEndsEditingAndKeepsTheDraft() throws {
        let chat = try chat()
        defer { chat.window.isHidden = true }
        try #require(chat.field.isFirstResponder)
        let tap = try #require(chat.scroll.gestureRecognizers?.first { $0 === chat.controller.transcriptTap },
                               "the transcript carries the tap that ends editing")
        #expect(!tap.cancelsTouchesInView, "the tap still reaches the row under it")
        chat.controller.endEditingFromTranscriptTap()
        #expect(!chat.surface.composerFocused, "the composer lets go of focus")
        #expect(!chat.field.isFirstResponder, "the keyboard goes down")
        #expect(chat.field.text == "a draft in progress", "the draft stays")
    }

    @Test func aTapWhileReadingMovesNothing() throws {
        let chat = try chat()
        defer { chat.window.isHidden = true }
        chat.field.resignFirstResponder()
        chat.surface.composerFocused = false
        let other = UITextField(frame: CGRect(x: 0, y: 0, width: 100, height: 30))
        chat.controller.view.addSubview(other)
        other.becomeFirstResponder()
        chat.controller.endEditingFromTranscriptTap()
        #expect(other.isFirstResponder, "a tap with the composer unfocused ends no other editing")
    }
}
#endif
