import AppKit
import CmuxNextAgentPane
@testable import CmuxNextApp
import CmuxNextDaemon
import CmuxNextPages
import Foundation
import Testing

@MainActor
@Suite struct TerminalHistoryPageTests {
    @Test func hookSessionSelectsOnlyItsOwnHarnessHistory() {
        let hook = "cmux-hook-shell"
        func status(_ agent: String, _ sessionID: String?) -> AgentStatus {
            AgentStatus(surface: 1, state: .idle, source: "hook", session: hook, agent: agent, agentSessionID: sessionID)
        }
        #expect(TerminalHistorySource.chatKey(status("claude_code", "same-id")) == "claude-code:same-id")
        #expect(TerminalHistorySource.chatKey(status("codex", "same-id")) == "codex:same-id")
        #expect(TerminalHistorySource.chatKey(status("claude", nil)) == nil)
        #expect(TerminalHistorySource.chatKey(status("muse", "same-id")) == nil)
        #expect(TerminalHistorySource.chatKey(nil) == nil)
    }

    @Test func clickingThePaneControlOpensOneRoutedPageAndKeepsTheTerminal() throws {
        let fixture = try TerminalChatSwitchMenuTests.Fixture()
        fixture.runAgent()
        fixture.pane.apply(fixture.pane.snapshot())
        let source = try #require(fixture.terminal.agent.flatMap { TerminalHistorySource.chatKey($0) })
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cn-terminal-history-root-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("<!doctype html><html data-cmux-page=\"terminal-history\"><body></body></html>".utf8)
            .write(to: root.appendingPathComponent("index.html"))
        PageID.registerBundledRoot(root, for: PageDescriptor.terminalHistory.id)
        let button = TerminalHistoryButton(source: TerminalHistorySource(key: source, cwd: nil), environment: nil) {
            WebPageTab.openTerminalHistory(TerminalHistorySource(key: source, cwd: nil), in: fixture.pane)
        }
        defer { button.discard() }

        button.performClick(nil)
        let pageID = InternalPageID(rawValue: "terminal-history")
        let provider = try #require(fixture.services.pages.provider(pageID) as? WebPageTab)
        let firstKey = try #require(fixture.services.pages.tabIDs(in: fixture.pane.paneKey).first { provider.route(for: $0) == source })
        #expect(LocalPageTab.page(of: firstKey) == pageID)
        #expect(fixture.pane.stripModel.selectedID?.rawValue == firstKey)
        #expect(fixture.pane.pane.tabs.contains { $0.id == fixture.terminal.id })

        button.performClick(nil)
        let matching = fixture.services.pages.tabIDs(in: fixture.pane.paneKey).filter { provider.route(for: $0) == source }
        #expect(matching == [firstKey])
        #expect(fixture.pane.stripModel.selectedID?.rawValue == firstKey)
    }

    @Test func compactAndFullPaneActionsShareOneAccessibleControl() {
        _ = NSApplication.shared
        var opened = 0
        let source = TerminalHistorySource(key: "codex:hook-id", cwd: nil)
        let button = TerminalHistoryButton(source: source, environment: nil) { opened += 1 }
        defer { button.discard() }
        let name = button.accessibilityLabel()
        _ = button.place(in: NSRect(x: 0, y: 0, width: 640, height: 300), top: 0, trailing: 0)
        #expect(button.imagePosition == .imageLeading)
        _ = button.place(in: NSRect(x: 0, y: 0, width: 84, height: 150), top: 0, trailing: 12)
        #expect(button.imagePosition == .imageOnly)
        #expect(name != nil && button.accessibilityLabel() == name)
        #expect(button.frame.width > 0 && button.frame.maxX <= 72)
        button.performClick(nil)
        #expect(opened == 1)
    }
}
