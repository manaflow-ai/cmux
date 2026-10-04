import AppKit
@testable import CmuxNextHome
import Foundation
import Testing

struct HomeViewTests {
    @Test func becomingFirstResponderFocusesTheComposer() async {
        let model = HomeViewModel()
        let actions = HomeMockActions(viewModel: model)
        let me = HomeParticipant(id: HomeFixture.me, displayName: "Me", isMe: true)
        let agent = HomeParticipant(id: HomeFixture.agent, displayName: "Mux", isAgent: true)
        actions.add(HomeMockSource(conversationID: "c", participants: [me, agent], history: HomeMemoryHistory([])), title: "Mux")
        let home = HomeView(viewModel: model)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled],
                              backing: .buffered, defer: true)
        window.contentView = home
        #expect(window.makeFirstResponder(home))
        for _ in 0..<5 where window.firstResponder !== home.composer.textView { await Task.yield() }
        #expect(window.firstResponder === home.composer.textView)
        window.contentView = nil
    }

    @Test func sendingGoesThroughTheActionsAsAPendingMessage() {
        let model = HomeViewModel()
        let actions = HomeMockActions(viewModel: model)
        actions.replies = false
        let me = HomeParticipant(id: HomeFixture.me, displayName: "Me", isMe: true)
        let agent = HomeParticipant(id: HomeFixture.agent, displayName: "Mux", isAgent: true)
        let source = HomeMockSource(conversationID: "c", participants: [me, agent], history: HomeMemoryHistory([]))
        actions.add(source, title: "Mux")
        let home = HomeView(viewModel: model)
        home.frame = CGRect(x: 0, y: 0, width: 800, height: 600)
        home.layoutSubtreeIfNeeded()
        home.composer.text = "hello"
        home.composer.textView.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        #expect(source.pendingMessages.map(\.parts) == [[.text("hello")]])
        #expect(home.composer.text.isEmpty)
    }
}
