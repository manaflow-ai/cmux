import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDesign
import CmuxNextHome
import CmuxHomeCore
import Testing
import CmuxNextTestSupport

/// Cmd-F in Home's Chief chat did nothing: Find and its neighbours refused a Home tab, the dock and a
/// conversation tab as "not a terminal", and the chat had no find bar. Now each Home container shows
/// the shared find pill over the transcript, with its field focused on the first press, as the agent
/// chat's Find in Chat does; Escape closes it and gives the keyboard back to the message box.
@MainActor @Suite(.closesItsWindows, .serialized, .timeLimit(.minutes(3))) struct HomeFindTests {
    enum Container: String, CaseIterable { case dock, homeTab, conversationTab }

    private static func wait(_ limit: Duration = .seconds(10), until done: () -> Bool) async {
        let deadline = ContinuousClock.now + limit
        // test-only: polls for the async Home view build in a hosted window, bounded by `limit`
        while !done(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(20)) }
    }

    /// One Home container in a real window, its message box with the keyboard.
    private static func harness(_ container: Container) async throws -> (window: NSWindow, content: TabContent, home: HomeHostView) {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let conversation = ConversationID("conv_home_find")
        let content: TabContent
        let host: () -> HomeHostView?
        switch container {
        case .dock:
            let dock = HomeDockView(services: services, mode: .messages)
            dock.messages?.show(conversation)
            content = .page(InternalPageView(key: "find-dock", page: .homeDock, content: dock))
            host = { dock.messages?.host }
        case .homeTab:
            let page = TopHomePageView(services: services, windowKey: { "home-find" })
            page.show(conversation)
            content = .page(InternalPageView(key: "find-tab", page: .homeTab, content: page))
            host = { page.host }
        case .conversationTab:
            let view = HomeHostView(services: services, conversation: conversation.rawValue)
            content = .conversation(view)
            host = { view }
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.titled, .resizable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        // Inside the content view at a fixed frame: as the window's content view, the chat's constraints sized the window
        // to their fitting size (1 x 0 on a macOS 26 worker), and the find bar had no room.
        content.view.frame = NSRect(x: 0, y: 0, width: 1200, height: 800)
        content.view.autoresizingMask = [.width, .height]
        window.contentView?.addSubview(content.view)
        window.orderFrontRegardless()
        content.view.layoutSubtreeIfNeeded()
        await wait { host()?.focusTarget is NSTextView }
        let home = try #require(host(), "Home shows no conversation")
        return (window, content, home)
    }

    /// Every container finds its chat's transcript, shows the pill with the field focused on the
    /// first call, and Escape (the pill's close) hides it and focuses the message box again.
    @Test(arguments: Container.allCases)
    func findShowsAFocusedPillAndEscapeGivesTheBoxTheKeyboard(_ container: Container) async throws {
        let h = try await Self.harness(container)
        defer { h.window.closeWithHomePopovers() }
        let box = try #require(h.home.focusTarget as? NSTextView, "\(container): no message box")
        h.window.makeFirstResponder(box)
        let transcript = try #require(HomeNativeTranscriptView.first(in: h.content.view), "\(container): no Home transcript")

        // The size again, with no suspension before the checks: on a macOS 26 worker the window was 1 x 0 by now (its size
        // changed during the harness's wait, while the route suite's app ran), and the find bar had no room.
        h.window.setContentSize(NSSize(width: 1200, height: 800))
        h.content.view.frame = NSRect(x: 0, y: 0, width: 1200, height: 800)
        h.content.view.layoutSubtreeIfNeeded()
        transcript.showFind(takeFocus: true)
        // A guard, not #require: a failed check would print (reflect) the transcript view, which aborts the run.
        guard let pill = transcript.findBar else { Issue.record("\(container): no find bar"); return }
        #expect(pill.isPresented, "\(container): the find bar is not shown")
        #expect(FindPillView.ownsFieldEditor(h.window.firstResponder), "\(container): the find field does not have the keyboard")
        #expect(pill.frame.width > 0 && pill.frame.height > 0, "\(container): the find bar has no frame: \(pill.frame) in \(transcript.bounds), window \(h.window.frame)")
        #expect(h.content.view.bounds.contains(transcript.convert(pill.frame, to: h.content.view)),
                "\(container): the find bar is outside the chat")
        // Typing in the field stays there: the message box does not take the keys.
        #expect(!h.home.focusTargetShouldTakeKeyboard(from: h.window.firstResponder), "\(container): the box takes the find field's keys")

        pill.perform(.close)
        #expect(!pill.isPresented, "\(container): Escape left the find bar shown")
        #expect(h.window.firstResponder === box, "\(container): the message box did not get the keyboard back")
    }
}
