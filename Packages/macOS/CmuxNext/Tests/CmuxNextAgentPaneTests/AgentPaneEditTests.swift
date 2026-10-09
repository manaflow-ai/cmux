import AppKit
import CmuxNextPages
import Foundation
import Testing
@testable import CmuxNextAgentPane

/// The composer's context menu (POLISH.md right-click contract, Leo 2026-10-08) runs Cut, Copy,
/// Paste and Paste as Plain Text through the host's own editing commands: `pane.edit {command}`.
/// Paste puts the user's pasteboard into the page, so it needs the user's real click or key in the
/// page view; the old bridge, which has no gesture context, never edits.
@MainActor
@Suite struct AgentPaneEditTests {
    @Test func thePageHostRunsOnlyTheFourCommands() async throws {
        let provider = AgentPageProvider { _ in nil }
        var edits: [AgentPaneEditCommand] = []
        provider.onEdit = { edits.append($0) }
        let gesture = PageCallContext(page: "agent", userGesture: true)
        for command in ["cut", "copy", "paste", "pasteAsPlainText"] {
            _ = try await provider.call("cmux.agent.pane.edit", params: ["command": .string(command)], context: gesture)
        }
        #expect(edits == [.cut, .copy, .paste, .pasteAsPlainText])
        await #expect(throws: PageError.self) {
            _ = try await provider.call("cmux.agent.pane.edit", params: ["command": "selectAll"], context: gesture)
        }
        #expect(edits.count == 4)
        #expect(AgentPageOps.all.contains("cmux.agent.pane.edit"))
    }

    @Test func anEditRunsOnlyOnTheUsersGesture() async throws {
        let provider = AgentPageProvider { _ in nil }
        var edits: [AgentPaneEditCommand] = []
        provider.onEdit = { edits.append($0) }
        do {
            _ = try await provider.call("cmux.agent.pane.edit", params: ["command": "paste"],
                                        context: PageCallContext(page: "agent"))
            Issue.record("an edit without a gesture ran")
        } catch let error as PageError {
            #expect(error.code == PageNativeOp.userOnlyCode)
        }
        #expect(edits.isEmpty)
        // The old bridge has no edit: it reads `pane.edit` as an unsupported method.
        #expect(AgentPaneRequest(body: ["method": "pane.edit", "params": ["command": "paste"]]) == .unsupported("pane.edit"))
    }

    @Test func thePageHostWiresEditsToItsPageView() throws {
        let index = try #require(AgentPaneView.bundledPage)
        let provider = AgentPageProvider { _ in nil }
        let page = try #require(AgentPanePageHost.makePage(root: index.deletingLastPathComponent(), provider: provider,
                                                           renderRate: .capped))
        _ = page
        #expect(provider.onEdit != nil)
    }

    @Test func eachCommandIsTheWebViewsOwnEditingAction() {
        #expect(AgentPaneEditCommand.cut.selector == #selector(NSText.cut(_:)))
        #expect(AgentPaneEditCommand.copy.selector == #selector(NSText.copy(_:)))
        #expect(AgentPaneEditCommand.paste.selector == #selector(NSText.paste(_:)))
        #expect(AgentPaneEditCommand.pasteAsPlainText.selector == NSSelectorFromString("pasteAsPlainText:"))
    }
}
