import AppKit
@testable import CmuxNextApp
import CmuxNextHome
import Testing

/// Two Chief conversations in one window (the docked Home and a conversation tab, or the Chief panel):
/// each one's Stop stops its own Chief. The restored native Home ran every Stop through
/// `home.stopChief` with no conversation, whose lookup took the window's first Home, so Stop in the
/// second conversation stopped the first or nothing (Codex review of #40611, F2).
@MainActor
struct HomeChiefTwoConversationsStopTests {
    struct Pair {
        let window: NSWindow
        let first: HomeHostView
        let second: HomeHostView
    }

    static func pair() -> Pair {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let first = HomeHostView(services: services, conversation: "conv_chief_one")
        let second = HomeHostView(services: services, conversation: "conv_chief_two")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 700), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 1200, height: 700))
        first.frame = NSRect(x: 0, y: 0, width: 600, height: 700)
        second.frame = NSRect(x: 600, y: 0, width: 600, height: 700)
        root.addSubview(first)
        root.addSubview(second)
        window.contentView = root
        return Pair(window: window, first: first, second: second)
    }

    @Test func eachConversationsStopButtonStopsItsOwnChief() {
        let pair = Self.pair()
        defer { pair.window.close() }
        var stopped: [String] = []
        for home in [pair.first, pair.second] {
            home.stopChief = { stopped.append($0.chiefControl.conversation.rawValue) }
        }
        pair.second.transcript.onStop()
        #expect(stopped == ["conv_chief_two"], "Stop in the second conversation stopped another Chief")
        pair.first.transcript.onStop()
        #expect(stopped == ["conv_chief_two", "conv_chief_one"])
    }

    @Test func theAppWideActionMeansTheConversationWithTheKeyboard() {
        let pair = Self.pair()
        defer { pair.window.close() }
        let pick: (NSView) -> HomeHostView? = { $0 as? HomeHostView }
        #expect(HomeShownView.find(in: pair.window, pick) === pair.first, "with no keyboard, the first visible Home")
        let field = NSTextField(frame: NSRect(x: 10, y: 10, width: 100, height: 22))
        pair.second.addSubview(field)
        #expect(pair.window.makeFirstResponder(field))
        #expect(HomeShownView.find(in: pair.window, pick) === pair.second, "the Home holding the keyboard comes first")
        pair.second.isHidden = true
        #expect(pair.window.makeFirstResponder(nil))
        #expect(HomeShownView.find(in: pair.window, pick) === pair.first, "a hidden Home is never picked")
    }
}
