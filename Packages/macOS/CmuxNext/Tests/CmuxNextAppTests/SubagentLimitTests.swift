@testable import CmuxNextApp
import CmuxNextDesign
import Foundation
import Testing

/// Subagent Limit… on a chat and a workspace: what the dialog shows, which answers become a
/// change, and the `_acpmux/subsession/limits` requests it sends (a read, then the change).
@MainActor struct SubagentLimitTests {
    /// A fake acpmux person connection that answers the limits method and records each request.
    final class FakeLine: AgentDialogLine {
        var isPerson = true
        var reply: [String: Any]?
        var sent: [[String: Any]] = []
        var closed = 0

        init(reply: [String: Any]?) { self.reply = reply }

        func call(_ method: String, _ params: [String: Any]) async -> [String: Any]? {
            guard method == SubagentLimit.method else { return nil }
            sent.append(params)
            return reply
        }

        func close() { closed += 1 }
    }

    private let chatReply: [String: Any] = [
        "sessionId": "s-1",
        "subsessionLimits": ["maxRunning": 4, "maxRunningSource": "session", "running": 3, "queued": 2, "maxChildren": 50],
    ]

    private func answer(_ button: String, _ text: String? = nil, role: CmuxDialogButton.Role = .normal) -> CmuxDialogAnswer {
        CmuxDialogAnswer(button: button, role: role, values: text.map { [SubagentLimit.field: .text($0)] } ?? [:])
    }

    private func flow(_ line: FakeLine, answer: CmuxDialogAnswer, shown: @escaping (CmuxDialogSpec) -> Void = { _ in })
        -> SubagentLimitFlow {
        SubagentLimitFlow(open: { line }, present: { spec in shown(spec); return answer }, setting: { 16 })
    }

    @Test func paramsReadSetAndClearAChat() {
        let chat = SubagentLimit.Scope.chat("s-1")
        #expect(chat.params(nil).keys.sorted() == ["sessionId"])
        #expect(chat.params(.set(8))["maxRunning"] as? Int == 8)
        #expect(chat.params(.useDefault)["maxRunning"] is NSNull)
    }

    @Test func paramsReadSetAndClearAWorkspace() throws {
        let workspace = try #require(SubagentLimit.Scope.workspace(key: "0F8FAD5BD9CB469FA16570867728950E"))
        #expect(workspace == .workspace("0f8fad5b-d9cb-469f-a165-70867728950e"))
        #expect(try #require(SubagentLimit.Scope.workspace(key: "0f8fad5b-d9cb-469f-a165-70867728950e")) == workspace)
        #expect(workspace.params(.set(2))["workspaceId"] as? String == "0f8fad5b-d9cb-469f-a165-70867728950e")
        #expect(workspace.params(nil)["maxRunning"] == nil)
        #expect(workspace.params(.useDefault)["maxRunning"] is NSNull)
        #expect(SubagentLimit.Scope.workspace(key: "ws_123") == nil)
    }

    @Test func currentReadsTheOwnValueOnlyWhenTheScopeSetIt() throws {
        let own = try #require(SubagentLimit.Current(reply: chatReply, scope: .chat("s-1")))
        #expect(own == SubagentLimit.Current(own: 4, effective: 4, running: 3, queued: 2))
        let inherited = try #require(SubagentLimit.Current(
            reply: ["subsessionLimits": ["maxRunning": 12, "maxRunningSource": "workspace"]], scope: .chat("s-1")))
        #expect(inherited.own == nil && inherited.effective == 12)
        // An acpmux from before maxRunning answers a chat's read without it.
        #expect(SubagentLimit.Current(reply: ["subsessionLimits": ["maxChildren": 50]], scope: .chat("s-1")) == nil)
        let workspace = SubagentLimit.Scope.workspace("0f8fad5b-d9cb-469f-a165-70867728950e")
        #expect(SubagentLimit.Current(reply: ["workspaceId": "x", "maxRunning": NSNull()], scope: workspace)?.own == nil)
        #expect(SubagentLimit.Current(reply: ["workspaceId": "x", "maxRunning": 6], scope: workspace)?.own == 6)
        // An acpmux from before maxRunning refuses a workspace's read; a reply without workspaceId is not one.
        #expect(SubagentLimit.Current(reply: ["maxRunning": 6], scope: workspace) == nil)
    }

    @Test func theDialogPrefillsTheOwnValueAndShowsTheOneInEffect() throws {
        let set = SubagentLimit(scope: .chat("s-1"), current: SubagentLimit.Current(own: 4, effective: 4, running: 3, queued: 2),
                                setting: 16).spec
        #expect(set.lines.count == 2)
        #expect(set.fields == [.text(SubagentLimit.field, initial: "4", label: SubagentLimitStrings.field, placeholder: "4")])
        #expect(set.buttons.map(\.id) == ["cancel", SubagentLimit.defaultButton, SubagentLimit.setButton])
        #expect(set.defaultButton?.id == SubagentLimit.setButton)
        let unset = SubagentLimit(scope: .chat("s-1"), current: SubagentLimit.Current(), setting: 16).spec
        #expect(unset.lines.count == 1)
        #expect(unset.fields == [.text(SubagentLimit.field, initial: "", label: SubagentLimitStrings.field, placeholder: "16")])
    }

    @Test func answersBecomeAChangeOnlyForANumberInRange() {
        #expect(SubagentLimit.change(for: answer(SubagentLimit.setButton, " 12 ")) == .success(.set(12)))
        #expect(SubagentLimit.change(for: answer(SubagentLimit.setButton, "1000")) == .success(.set(1000)))
        #expect(SubagentLimit.change(for: answer(SubagentLimit.setButton, "")) == .success(.useDefault))
        #expect(SubagentLimit.change(for: answer(SubagentLimit.defaultButton, "7")) == .success(.useDefault))
        for bad in ["0", "1001", "-3", "2.5", "many"] {
            #expect(SubagentLimit.change(for: answer(SubagentLimit.setButton, bad)) == .failure(SubagentLimit.InvalidNumber()), "\(bad)")
        }
        #expect(SubagentLimit.change(for: answer("cancel", "5", role: .cancel)) == nil)
        var dismissed = answer(SubagentLimit.setButton, "5")
        dismissed.isDismissal = true
        #expect(SubagentLimit.change(for: dismissed) == nil)
    }

    @Test func settingAChatsLimitReadsThenSendsTheNumber() async {
        let line = FakeLine(reply: chatReply)
        var shown: CmuxDialogSpec?
        let failure = await flow(line, answer: answer(SubagentLimit.setButton, "9"), shown: { shown = $0 }).run(.chat("s-1"))
        #expect(failure == nil)
        #expect(shown?.fields.first == .text(SubagentLimit.field, initial: "4", label: SubagentLimitStrings.field, placeholder: "4"))
        #expect(line.sent.count == 2)
        #expect(line.sent.first?.keys.sorted() == ["sessionId"])
        #expect(line.sent.last?["sessionId"] as? String == "s-1")
        #expect(line.sent.last?["maxRunning"] as? Int == 9)
        #expect(line.closed == 2)
    }

    /// A workspace's dialog says it applies to each chat in it and shows the global setting as its
    /// placeholder (a workspace has no value in effect of its own).
    @Test func aWorkspacesDialogShowsTheSettingAsItsPlaceholder() {
        let spec = SubagentLimit(scope: .workspace("w"), current: SubagentLimit.Current(own: 3), setting: 16).spec
        #expect(spec.lines == [SubagentLimitStrings.workspaceLine])
        #expect(spec.fields == [.text(SubagentLimit.field, initial: "3", label: SubagentLimitStrings.field, placeholder: "16")])
    }

    @Test func useDefaultClearsAWorkspacesLimit() async {
        let workspace = "0f8fad5b-d9cb-469f-a165-70867728950e"
        let line = FakeLine(reply: ["workspaceId": workspace, "maxRunning": 3])
        let failure = await flow(line, answer: answer(SubagentLimit.defaultButton, "3")).run(.workspace(workspace))
        #expect(failure == nil)
        #expect(line.sent.count == 2)
        #expect(line.sent.first?["workspaceId"] as? String == workspace && line.sent.first?["maxRunning"] == nil)
        #expect(line.sent.last?["workspaceId"] as? String == workspace)
        #expect(line.sent.last?["maxRunning"] is NSNull)
    }

    @Test func useDefaultClearsAChatsLimit() async {
        let line = FakeLine(reply: chatReply)
        let failure = await flow(line, answer: answer(SubagentLimit.defaultButton, "3")).run(.chat("s-1"))
        #expect(failure == nil)
        #expect(line.sent.count == 2)
        #expect(line.sent.last?["sessionId"] as? String == "s-1")
        #expect(line.sent.last?["maxRunning"] is NSNull)
    }

    @Test func cancelAnInvalidNumberOrAnOldAcpmuxSendNoChange() async {
        let cancelled = FakeLine(reply: chatReply)
        #expect(await flow(cancelled, answer: answer("cancel", role: .cancel)).run(.chat("s-1")) == nil)
        #expect(cancelled.sent.count == 1)

        let invalid = FakeLine(reply: chatReply)
        #expect(await flow(invalid, answer: answer(SubagentLimit.setButton, "0")).run(.chat("s-1"))?.message
            == SubagentLimitStrings.invalid)
        #expect(invalid.sent.count == 1)

        var asked = false
        let old = FakeLine(reply: ["subsessionLimits": ["maxChildren": 50]])
        #expect(await flow(old, answer: answer(SubagentLimit.setButton, "5"), shown: { _ in asked = true }).run(.chat("s-1"))?.message
            == SubagentLimitStrings.unsupported)
        #expect(!asked && old.sent.count == 1)
    }

    /// No acpmux, a connection that failed the person proof, or a refused read is not an old acpmux:
    /// it says the limit could not be read, opens no dialog and sends nothing on a line that is
    /// not the person.
    @Test func anUnansweredReadSaysItCouldNotBeRead() async {
        var asked = false
        let refused = FakeLine(reply: nil)
        #expect(await flow(refused, answer: answer(SubagentLimit.setButton, "5"), shown: { _ in asked = true }).run(.chat("s-1"))?
            .message == SubagentLimitStrings.unreadable)
        #expect(refused.sent.count == 1)

        let notPerson = FakeLine(reply: chatReply)
        notPerson.isPerson = false
        #expect(await flow(notPerson, answer: answer(SubagentLimit.setButton, "5"), shown: { _ in asked = true }).run(.chat("s-1"))?
            .message == SubagentLimitStrings.unreadable)
        #expect(notPerson.sent.isEmpty && notPerson.closed == 1)

        let setFive = answer(SubagentLimit.setButton, "5")
        let none = SubagentLimitFlow(open: { nil }, present: { _ in asked = true; return setFive }, setting: { 16 })
        #expect(await none.run(.chat("s-1"))?.message == SubagentLimitStrings.unreadable)
        #expect(!asked)
        #expect(SubagentLimitStrings.unreadable != SubagentLimitStrings.unsupported)
    }
}
