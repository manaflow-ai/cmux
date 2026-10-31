#if os(iOS)
import Foundation
import SwiftUI
import Testing
import UIKit
@testable import CmuxMobileAgentChat

/// Typing "/" listed every slash command in a plain stack of fixed 44 pt rows: twenty
/// commands asked for 880 pt above the composer, the dock measures its stack at its ideal
/// height and proposes none, so on a small iPhone the list ran past the screen and the
/// first commands could not be reached. The list now takes the room under the chat's
/// header and scrolls the rest; every command stays in it, and its rows grow with
/// Dynamic Type. Not every row has to be visible at once, only reachable by scrolling.
@MainActor
@Suite struct SlashSuggestionsReachTests {
    final class Silent: AgentSessionSource {
        let summary = AgentSessionSummary(id: "s", name: "S", harness: "codex", agentName: "Codex", cwd: "~", workspaceTitle: "w", macName: "m")
        func events() -> AsyncStream<AgentSessionEvent> { AsyncStream { _ in } }
        func send(_ intent: AgentClientIntent) {}
    }

    static let commands = (1 ... 20).map { ACPAvailableCommand(name: "command\($0)", description: "Command number \($0)") }
    /// The rows' least height (a touch target).
    static let rowHeight: CGFloat = 44

    struct Chat {
        let window: UIWindow
        let surface: AgentChatSurface
        let controller: ChatTranscriptController
    }

    /// The pushed chat's transcript and dock as `AgentChatTranscript` builds them, on an
    /// iPhone SE sized screen, with "/" typed and twenty commands available.
    private func pushedChat(_ dynamicType: DynamicTypeSize) -> Chat {
        let store = AgentChatStore(source: Silent())
        store.apply(.update(.availableCommands(Self.commands)))
        let surface = AgentChatSurface()
        surface.text = "/"
        let dock = AnyView(AgentChatBottomStack(store: store, surface: surface, bottomPadding: 0).dynamicTypeSize(dynamicType))
        let controller = ChatTranscriptController(placement: .owned, surface: surface, store: store,
                                                  empty: AnyView(EmptyView()), dock: dock, jump: nil)
        controller.isEmpty = true
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 375, height: 667))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        drain()
        return Chat(window: window, surface: surface, controller: controller)
    }

    /// Lets SwiftUI lay the dock out and report its geometry (a reported frame can set
    /// state that lays it out again).
    private func drain() {
        for _ in 0 ..< 50 { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    }

    /// The scroll view holding the slash commands: the one whose content is as tall as
    /// every command row (the composer's field is a text view; the transcript is empty).
    private func suggestionList(in view: UIView) -> UIScrollView? {
        if let scroll = view as? UIScrollView, !(view is UITextView),
           scroll.contentSize.height >= CGFloat(Self.commands.count) * Self.rowHeight - 0.5 {
            return scroll
        }
        for subview in view.subviews {
            if let found = suggestionList(in: subview) { return found }
        }
        return nil
    }

    @Test func everySlashCommandIsReachableOnASmallPhone() throws {
        let chat = pushedChat(.large)
        defer { chat.window.isHidden = true }
        let stackHeight = try #require(chat.surface.stackHeight)
        let stackTop = try #require(chat.surface.bottomStackTop)
        // The stack stays inside the dock's host and on the screen.
        #expect(stackHeight <= ChatTranscriptController.dockHostHeight, "the stack is \(stackHeight) pt tall")
        #expect(stackTop >= 0, "the stack's top is \(stackTop) pt, above the screen")

        // One scroll view holds every command, and shows less than all of them.
        let list = try #require(suggestionList(in: chat.window), "no scroll view holds all \(Self.commands.count) commands")
        let shown = list.convert(list.bounds, to: nil)
        #expect(shown.minY >= 0 && shown.maxY <= chat.window.bounds.maxY, "the list is drawn at \(shown)")
        #expect(list.bounds.height < list.contentSize.height)
        #expect(list.isScrollEnabled)

        // Scrolled to its end, the last command's row is in the list's viewport.
        let end = list.contentSize.height + list.adjustedContentInset.bottom - list.bounds.height
        list.setContentOffset(CGPoint(x: 0, y: end), animated: false)
        drain()
        let lastRow = CGRect(x: 0, y: list.contentSize.height - Self.rowHeight, width: list.bounds.width, height: Self.rowHeight)
        #expect(list.bounds.contains(lastRow), "after scrolling the viewport is \(list.bounds), the last row \(lastRow)")
    }

    @Test func rowsGrowWithDynamicType() throws {
        let chat = pushedChat(.accessibility3)
        defer { chat.window.isHidden = true }
        let list = try #require(suggestionList(in: chat.window), "no scroll view holds all \(Self.commands.count) commands")
        // Taller than twenty fixed 44 pt rows: each row takes its text's height.
        #expect(list.contentSize.height > CGFloat(Self.commands.count) * Self.rowHeight + 1, "the rows are \(list.contentSize.height) pt in all")
        let stackHeight = try #require(chat.surface.stackHeight)
        #expect(stackHeight <= ChatTranscriptController.dockHostHeight, "the stack is \(stackHeight) pt tall")
    }
}
#endif
