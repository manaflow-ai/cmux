@testable import CmuxNextApp
import CmuxNextDesign
import CmuxNextSessionTransfer
import CmuxNextSettings
import Foundation
import Testing

/// The picker and toast of Move Sessions from Another cmux Build… (cx-yxmkh):
/// the rows each build gets, the sessions a checked set moves, that the default
/// answer never ends a terminal, and what the toast says after the pulls.
@Suite struct SessionMoveSelectionTests {
    static func item(_ id: String, _ kind: SessionTransferItem.Kind = .terminal, title: String = "", cwd: String? = nil,
                     activity: SessionTransferItem.Activity = .idle) -> SessionTransferItem {
        var item = SessionTransferItem(sourceSurface: id, workspace: "w", kind: kind, title: title, cwd: cwd, sshTarget: nil,
                                       command: nil, agentHarness: nil, agentSessionID: nil)
        item.activity = activity
        return item
    }

    /// One build with an idle, a busy and an unreported terminal, a chat and an agent.
    static let mixed = [
        peer("/tmp/mixed.sock", app: "cmux DEV", tag: nil, [
            item("t1", title: "shell"), item("t2", title: "editor", activity: .running("vim")),
            item("t3", title: "old", activity: .unknown), item("c1", .chat, title: "chat"), item("a1", .agent, title: "agent"),
        ]),
    ]

    /// The answer the dialog gives when Return is pressed with every box as it started.
    static func returnAnswer(_ dialog: CmuxDialogSpec) -> CmuxDialogAnswer? {
        guard case .press(let button)? = CmuxDialogKeys.action(for: .return, modifiers: [], in: dialog),
              let pressed = dialog.buttons.first(where: { $0.id == button }) else { return nil }
        let values = dialog.fields.reduce(into: [String: CmuxDialogValue]()) { values, field in
            if case .check(let id, _, let on) = field { values[id] = .bool(on) }
        }
        return CmuxDialogAnswer(button: button, role: pressed.role, values: values)
    }

    static func peer(_ path: String, app: String, tag: String?, _ items: [SessionTransferItem]) -> SessionTransferPeer {
        SessionTransferPeer(path: path, app: app, build: "1", tag: tag, pid: 1, items: items)
    }

    static let peers = [
        peer("/tmp/dev.sock", app: "cmux DEV", tag: "wallpapers", [item("1", title: "server"), item("2", .chat, title: "fix the build")]),
        peer("/tmp/empty.sock", app: "cmux NEXT", tag: nil, []),
        peer("/tmp/nightly.sock", app: "cmux NIGHTLY", tag: nil, [item("1", cwd: "/Users/me/src/site"), item("9", .agent)]),
    ]

    @Test func eachBuildWithSessionsIsAGroupNamedByAppAndTag() {
        let selection = SessionMoveSelection(peers: Self.peers)
        #expect(selection.groups.map(\.heading) == ["cmux DEV (wallpapers)", "cmux NIGHTLY"])
        #expect(selection.groups.map(\.source) == ["/tmp/dev.sock", "/tmp/nightly.sock"])
        #expect(selection.groups[0].rows.map(\.title) == ["server", "fix the build"])
        // No title: the folder's name, else the kind of session.
        #expect(selection.groups[1].rows.map(\.title) == ["site", SessionMoveSelection.agentChat])
        #expect(SessionMoveSelection(peers: [Self.peers[1]]).isEmpty)
    }

    @Test func theDialogShowsEachBuildThenItsSessionsWithTerminalsUnchecked() {
        let dialog = SessionMoveSelection(peers: Self.peers).dialog
        let checks = dialog.fields.compactMap { field -> Bool? in
            if case .check(_, _, let on) = field { on } else { nil }
        }
        // server (terminal), fix the build (chat), site (terminal), the agent.
        #expect(checks == [false, true, false, true])
        #expect(dialog.fields.first == .preview("cmux DEV (wallpapers)"))
        #expect(dialog.defaultButton?.id == SessionMoveSelection.moveButton)
        #expect(dialog.cancelButton != nil)
        let fieldIDs = dialog.fields.compactMap(\.id)
        #expect(Set(fieldIDs).count == fieldIDs.count, "field ids are unique across builds")
    }

    @Test func checkedRowsMoveOnlyTheirSessionsFromTheirBuild() {
        let selection = SessionMoveSelection(peers: Self.peers)
        let dev = selection.groups[0].rows, nightly = selection.groups[1].rows
        let pulls = selection.pulls(checked: [dev[1].field, nightly[0].field, nightly[1].field])
        #expect(pulls == [
            SessionMoveSelection.Pull(source: "/tmp/dev.sock", heading: "cmux DEV (wallpapers)", ids: ["2"]),
            SessionMoveSelection.Pull(source: "/tmp/nightly.sock", heading: "cmux NIGHTLY", ids: ["1", "9"]),
        ])
    }

    /// `pull` with no ids moves every session of the build: a build with
    /// nothing checked must not be pulled at all.
    @Test func aBuildWithNothingCheckedIsNotPulled() {
        let selection = SessionMoveSelection(peers: Self.peers)
        let pulls = selection.pulls(checked: [selection.groups[1].rows[0].field])
        #expect(pulls.map(\.source) == ["/tmp/nightly.sock"])
        #expect(pulls.first?.ids == ["1"])
        #expect(selection.pulls(checked: []).isEmpty)
    }

    @Test func onlyMoveMovesAnything() {
        let selection = SessionMoveSelection(peers: Self.peers)
        let all = Dictionary(uniqueKeysWithValues: selection.groups.flatMap(\.rows).map { ($0.field, CmuxDialogValue.bool(true)) })
        #expect(selection.pulls(CmuxDialogAnswer(button: SessionMoveSelection.moveButton, role: .default, values: all)).count == 2)
        #expect(selection.pulls(CmuxDialogAnswer(button: "cancel", role: .cancel, values: all)).isEmpty)
        #expect(selection.pulls(CmuxDialogAnswer(button: "cancel", role: .cancel, values: all, isDismissal: true)).isEmpty)
    }

    /// Return with the boxes as they start moves the chats and agents and never a terminal,
    /// so it never asks to end one.
    @Test func theDefaultAnswerNeverEndsATerminal() throws {
        let selection = SessionMoveSelection(peers: Self.mixed + Self.peers)
        let answer = try #require(Self.returnAnswer(selection.dialog))
        #expect(answer.button == SessionMoveSelection.moveButton)
        let pulls = selection.pulls(answer)
        let terminals = Set(selection.groups.flatMap { group in group.rows.filter(\.isTerminal).map { "\(group.source) \($0.item)" } })
        let moved = Set(pulls.flatMap { pull in pull.ids.map { "\(pull.source) \($0)" } })
        #expect(!moved.isEmpty)
        #expect(moved.isDisjoint(with: terminals))
        #expect(selection.terminals(in: pulls).isEmpty)
    }

    /// A terminal running a program, or whose build can't tell, has no check box and
    /// never moves, even when an answer names its field.
    @Test func aBusyTerminalCannotBeSelected() {
        let selection = SessionMoveSelection(peers: Self.mixed)
        let rows = selection.groups[0].rows
        #expect(rows[1].blocked == SessionMoveSelection.running("editor", "vim"))
        #expect(rows[2].blocked == SessionMoveSelection.unknownActivity("old"))
        #expect(rows[0].blocked == nil && rows[3].blocked == nil && rows[4].blocked == nil)
        let checkIDs = Set(selection.dialog.fields.compactMap(\.id))
        #expect(!checkIDs.contains(rows[1].field) && !checkIDs.contains(rows[2].field))
        #expect(selection.dialog.fields.contains(.preview(SessionMoveSelection.running("editor", "vim"))))

        let all = Dictionary(uniqueKeysWithValues: rows.map { ($0.field, CmuxDialogValue.bool(true)) })
        let pulls = selection.pulls(CmuxDialogAnswer(button: SessionMoveSelection.moveButton, role: .default, values: all))
        #expect(pulls.first?.ids == ["t1", "c1", "a1"])
        #expect(selection.pulls(checked: [rows[1].field, rows[2].field]).isEmpty)
    }

    /// Ticking a terminal makes the move ask again: its confirm is Move and End Terminals,
    /// destructive, and Return presses nothing there. With no terminal ticked, Move is Return's.
    @Test func aTickedTerminalNeedsMoveAndEndTerminalsWhichReturnNeverPresses() {
        let selection = SessionMoveSelection(peers: Self.mixed)
        #expect(selection.dialog.defaultButton?.id == SessionMoveSelection.moveButton)
        let rows = selection.groups[0].rows
        let pulls = selection.pulls(checked: [rows[0].field, rows[3].field])
        #expect(selection.terminals(in: pulls) == ["shell"])

        let confirm = SessionMoveSelection.endTerminalsDialog(for: selection.terminals(in: pulls))
        #expect(confirm.defaultButton == nil)
        #expect(CmuxDialogKeys.action(for: .return, modifiers: [], in: confirm) == nil)
        #expect(CmuxDialogKeys.action(for: .return, modifiers: .command, in: confirm) == nil)
        let end = confirm.buttons.first { $0.id == SessionMoveSelection.endTerminalsButton }
        #expect(end?.role == .destructive)
        #expect(end?.title == SessionMoveSelection.moveAndEndTerminals)
        #expect(confirm.fields == [.preview("shell")])

        let cancel = confirm.cancelButton
        #expect(CmuxDialogKeys.action(for: .escape, modifiers: [], in: confirm) == cancel.map { CmuxDialogKeys.Action.press($0.id) })
        #expect(!SessionMoveSelection.confirmsEndingTerminals(CmuxDialogAnswer(button: "cancel", role: .cancel)))
        #expect(!SessionMoveSelection.confirmsEndingTerminals(
            CmuxDialogAnswer(button: SessionMoveSelection.endTerminalsButton, role: .destructive, isDismissal: true)))
        #expect(SessionMoveSelection.confirmsEndingTerminals(
            CmuxDialogAnswer(button: SessionMoveSelection.endTerminalsButton, role: .destructive)))
    }

    /// `idle` and `foreground_program` round-trip; a build that sends neither is unknown.
    @Test func terminalActivityRoundTripsAndDefaultsToUnknown() {
        for activity: SessionTransferItem.Activity in [.idle, .running("ssh"), .unknown] {
            #expect(SessionTransferItem(json: Self.item("1", activity: activity).json)?.activity == activity)
        }
        let old: CmuxNextSettings.JSONValue = ["surface": .string("1"), "kind": .string("terminal")]
        #expect(SessionTransferItem(json: old)?.activity == .unknown)
    }

    /// Right before a picked terminal is ended in its build, its build is asked again: only a
    /// terminal still idle there moves. One that runs a program now, whose build can't tell,
    /// that is gone, or whose build gave no answer stays, and the toast says why.
    @Test func aPickedTerminalThatBecameBusyStays() {
        func list(_ items: SessionTransferItem...) -> CmuxNextSettings.JSONValue {
            ["sessions": .array(items.map(\.json))]
        }
        #expect(SessionMoveSelection.handoffRefusal(surface: "1", list: list(Self.item("1"))) == nil)
        #expect(SessionMoveSelection.handoffRefusal(surface: "1", list: list(Self.item("1", activity: .running("vim"))))
            == SessionMoveSelection.becameBusy("vim"))
        #expect(SessionMoveSelection.handoffRefusal(surface: "1", list: list(Self.item("1", activity: .running(""))))
            == SessionMoveSelection.becameUnknown)
        #expect(SessionMoveSelection.handoffRefusal(surface: "1", list: list(Self.item("1", activity: .unknown)))
            == SessionMoveSelection.becameUnknown)
        // Another terminal being idle says nothing about this one.
        #expect(SessionMoveSelection.handoffRefusal(surface: "1", list: list(Self.item("2"))) == SessionMoveSelection.becameUnknown)
        #expect(SessionMoveSelection.handoffRefusal(surface: "1", list: nil) == SessionMoveSelection.becameUnknown)

        // The refusal is the failure's message, so the toast names the terminal and the reason.
        let reason = SessionTransferService.message(for: SessionTransferService.Failure.terminalBusy(SessionMoveSelection.becameBusy("vim")))
        #expect(reason == SessionMoveSelection.becameBusy("vim"))
        var outcome = SessionMoveOutcome()
        outcome.record(["moved": .array([]), "failed": .array([.object(["surface": .string("1"), "error": .string(reason)])])],
                       titles: ["1": "editor"])
        #expect(outcome.notice == SessionMoveOutcome.couldNotMove("editor", SessionMoveSelection.becameBusy("vim")))
    }

    @Test func theToastSaysWhatMovedAndNamesEachFailure() {
        let selection = SessionMoveSelection(peers: Self.peers)
        var outcome = SessionMoveOutcome()
        outcome.record(["moved": .array([.object(["surface": .string("1")])]), "failed": .array([])],
                       titles: selection.titles(in: "/tmp/dev.sock"))
        #expect(outcome.notice == SessionMoveOutcome.movedAll)

        outcome.record(["moved": .array([]), "failed": .array([.object(["surface": .string("1"), "error": .string("busy.")])])],
                       titles: selection.titles(in: "/tmp/nightly.sock"))
        // The nightly build's session 1 is "site", not the dev build's "server".
        #expect(outcome.notice == [SessionMoveOutcome.movedOthers, SessionMoveOutcome.couldNotMove("site", "busy.")].joined(separator: " "))

        var refused = SessionMoveOutcome()
        refused.record(failure: SessionTransferService.message(for: SessionTransferService.Failure.peerRefused), from: "cmux NIGHTLY")
        #expect(refused.notice == SessionMoveOutcome.couldNotMove(
            from: "cmux NIGHTLY", SessionTransferService.message(for: SessionTransferService.Failure.peerRefused)))
        #expect(SessionMoveOutcome().notice == SessionMoveOutcome.nothingMoved)
    }
}
