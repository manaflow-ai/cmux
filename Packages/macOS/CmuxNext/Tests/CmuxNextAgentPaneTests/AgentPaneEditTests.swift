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
    @Test func theEditRequestDecodesOnlyTheFourCommands() {
        for command in ["cut", "copy", "paste", "pasteAsPlainText"] {
            #expect(AgentPaneRequest(body: ["method": "pane.edit", "params": ["command": command]])
                == .edit(AgentPaneEditCommand(rawValue: command)!))
        }
        #expect(AgentPaneRequest(body: ["method": "pane.edit", "params": ["command": "selectAll"]]) == .unsupported("pane.edit"))
        #expect(AgentPageOps.all.contains("cmux.agent.pane.edit"))
    }

    @Test func anEditRunsOnlyOnTheUsersGesture() async throws {
        let model = AgentPaneModel(host: MockAgentPaneHost())
        var edits: [AgentPaneEditCommand] = []
        model.onEdit = { edits.append($0) }
        let provider = AgentPageProvider { _ in model }
        do {
            _ = try await provider.call("cmux.agent.pane.edit", params: ["command": "paste"],
                                        context: PageCallContext(page: "agent"))
            Issue.record("an edit without a gesture ran")
        } catch let error as PageError {
            #expect(error.code == PageNativeOp.userOnlyCode)
        }
        #expect(edits.isEmpty)
        _ = try await provider.call("cmux.agent.pane.edit", params: ["command": "pasteAsPlainText"],
                                    context: PageCallContext(page: "agent", userGesture: true))
        #expect(edits == [.pasteAsPlainText])
        let reply = await model.respond(to: .edit(.copy))
        #expect(reply["ok"] as? Bool == false)
        #expect(edits == [.pasteAsPlainText])
    }

    @Test func eachCommandIsTheWebViewsOwnEditingAction() {
        #expect(AgentPaneEditCommand.cut.selector == #selector(NSText.cut(_:)))
        #expect(AgentPaneEditCommand.copy.selector == #selector(NSText.copy(_:)))
        #expect(AgentPaneEditCommand.paste.selector == #selector(NSText.paste(_:)))
        #expect(AgentPaneEditCommand.pasteAsPlainText.selector == NSSelectorFromString("pasteAsPlainText:"))
    }
}
