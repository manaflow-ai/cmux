@testable import CmuxNextApp
import CmuxNextDesign
import CmuxNextSessionTransfer
import CmuxNextSettings
import Foundation
import Testing

/// The picker and toast of Move Sessions from Another cmux Build… (cx-yxmkh):
/// the rows each build gets, the sessions a checked set moves, and what the
/// toast says after the pulls.
@Suite struct SessionMoveSelectionTests {
    static func item(_ id: String, _ kind: SessionTransferItem.Kind = .terminal, title: String = "", cwd: String? = nil) -> SessionTransferItem {
        SessionTransferItem(sourceSurface: id, workspace: "w", kind: kind, title: title, cwd: cwd, sshTarget: nil,
                            command: nil, agentHarness: nil, agentSessionID: nil)
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

    @Test func theDialogShowsEachBuildThenItsSessionsAllChecked() {
        let dialog = SessionMoveSelection(peers: Self.peers).dialog
        let checks = dialog.fields.compactMap { field -> Bool? in
            if case .check(_, _, let on) = field { on } else { nil }
        }
        #expect(checks == [true, true, true, true])
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
