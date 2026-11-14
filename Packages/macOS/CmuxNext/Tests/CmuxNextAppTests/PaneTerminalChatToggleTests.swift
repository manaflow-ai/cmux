import AppKit
import CmuxNextActions
@testable import CmuxNextApp
@testable import CmuxNextDaemon
@testable import CmuxNextTabs
import CmuxNextWindowRules
import Foundation
import Testing

/// Toggle Terminal and Chat's control in the pane toolbar (`design/terminal-chat-toggle.md`; Leo 2026-11-12:
/// "we can toggle it, like from the terminal into the GUI, or vice versa, back and forth"): a `>_ | bubble` pair
/// of segments that shows only on a terminal and chat pair, lights the selected tab's face, sits at one x on both
/// faces, and runs `palette.toggleTerminalChat` through the registry, as its key does.
@MainActor @Suite(.serialized)
struct PaneTerminalChatToggleTests {
    static let toggle: ActionID = "palette.toggleTerminalChat"

    final class Recorder { var invocations: [ActionInvocation] = [] }

    static func toolbar() -> (PaneToolbar, Recorder) {
        _ = NSApplication.shared
        let registry = ActionRegistry(catalog: [.init(id: toggle, title: "Toggle Terminal and Chat", category: .other)])
        let recorder = Recorder()
        registry.bind(toggle, invoke: { recorder.invocations.append($0) })
        let toolbar = PaneToolbar(registry: { registry }, newTabMenu: { nil })
        toolbar.view.frame = NSRect(x: 0, y: 0, width: 200, height: 32)
        return (toolbar, recorder)
    }

    // Pair membership is the Rust route's answer (cmux-window-rules `tabs::terminal_chat_toggle`) for the facts the
    // action builds: a refusal shows no control.
    @Test func theControlShowsOnlyForAPair() {
        let rules = WindowRules()
        let face = { (facts: WindowRules.ToggleFacts) in TerminalChatHandler.face(rules.terminalChatToggle(facts), terminal: facts.terminal) }
        // A terminal running a Claude Code session, and the chat resuming one a terminal runs: a pair.
        #expect(face(.init(terminal: true, agent: "claude", session: "s-1")) == .terminal)
        #expect(face(.init(chat: true, agent: "codex", session: "s-2", running: true)) == .chat)
        // A chat whose terminal is gone is still one half: the press resumes the session in a terminal.
        #expect(face(.init(chat: true, agent: "codex", session: "s-2")) == .chat)
        #expect(face(.init(chat: true, agent: "codex", session: "s-2", busy: true)) == .chat)
        // A plain terminal, a cmux chat with no outside session, an agent acpmux cannot resume: none.
        #expect(face(.init(terminal: true, agent: nil, session: nil)) == nil)
        #expect(face(.init(chat: true, agent: nil, session: nil)) == nil)
        #expect(face(.init(terminal: true, agent: "opencode", session: "x")) == nil)
        #expect(face(.init(agent: "claude", session: "s")) == nil)
    }

    @Test func aPlainTerminalTabShowsNoControl() {
        let services = TerminalChatTests.services()
        let tab = TabModel(TabSnapshot(surface: SurfaceID(rawValue: 1)))
        #expect(TerminalChatHandler.face(of: tab, services: services) == nil)
        tab.agent = AgentStatus(surface: SurfaceID(rawValue: 1), state: .idle, session: "s-1", agent: "claude")
        #expect(TerminalChatHandler.face(of: tab, services: services) == .terminal)
    }

    @Test func theSelectedTabsFaceIsLit() throws {
        let (toolbar, _) = Self.toolbar()
        let control = toolbar.view.terminalChatToggle
        toolbar.update(target: "term", kind: .terminal, paneKinds: [.terminal], terminalChat: .terminal, paneHasTerminalChat: true)
        #expect(!control.isHidden)
        #expect(control.terminalButton.state == .on && control.chatButton.state == .off)
        #expect(control.terminalButton.themedToolTip == "Toggle Terminal and Chat")
        #expect(control.accessibilityRole() == .radioGroup)
        #expect(control.terminalButton.accessibilityLabel() == "Terminal" && control.chatButton.accessibilityLabel() == "Chat")
        toolbar.update(target: "chat", kind: nil, paneKinds: [.terminal], terminalChat: .chat, paneHasTerminalChat: true)
        #expect(!control.isHidden)
        #expect(control.chatButton.state == .on && control.terminalButton.state == .off)
        // Another tab of the pane, not a pair: no control, its room kept.
        toolbar.update(target: "other", kind: .terminal, paneKinds: [.terminal], terminalChat: nil, paneHasTerminalChat: true)
        #expect(control.isHidden)
        #expect(toolbar.view.reservesTerminalChat)
        toolbar.update(target: "other", kind: .terminal, paneKinds: [.terminal])
        #expect(control.isHidden && !toolbar.view.reservesTerminalChat)
    }

    @Test func pressingTheOtherFaceRunsTheToggleAction() throws {
        let (toolbar, recorder) = Self.toolbar()
        let control = toolbar.view.terminalChatToggle
        toolbar.update(target: "term", kind: .terminal, paneKinds: [.terminal], terminalChat: .terminal, paneHasTerminalChat: true)
        control.terminalButton.performClick(nil) // the lit face: nothing
        #expect(recorder.invocations.isEmpty)
        control.chatButton.performClick(nil)
        let run = try #require(recorder.invocations.first)
        #expect(recorder.invocations.count == 1)
        #expect(run.target == ActionTargetRef(kind: .tab, id: "term"))
    }

    // Same x on both faces: beside a chat the bar keeps "…"'s empty slot right of the toggle, so the bar's width
    // beside the chat's own tools equals its width over the terminal and the chat's tools move left by it.
    @Test func theControlSitsAtOneXOnBothFaces() {
        let (toolbar, _) = Self.toolbar()
        let view = toolbar.view
        toolbar.update(target: "term", kind: .terminal, paneKinds: [.terminal], terminalChat: .terminal, paneHasTerminalChat: true)
        let terminalWidth = view.intrinsicContentSize.width
        view.frame.size.width = terminalWidth
        view.layoutSubtreeIfNeeded()
        let terminalGap = view.bounds.maxX - view.terminalChatToggle.frame.maxX
        toolbar.update(target: "chat", kind: nil, paneKinds: [.terminal], terminalChat: .chat, paneHasTerminalChat: true)
        #expect(view.tabRowWidth == terminalWidth)
        view.frame.size.width = view.tabRowWidth
        view.layoutSubtreeIfNeeded()
        #expect(view.bounds.maxX - view.terminalChatToggle.frame.maxX == terminalGap)
        #expect(view.terminalChatToggle.frame.width == PaneTerminalChatToggleView.width)
    }
}
