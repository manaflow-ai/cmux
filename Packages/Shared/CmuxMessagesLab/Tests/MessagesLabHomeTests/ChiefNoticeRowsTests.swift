import AppKit
import CmuxHomeCore
import Foundation
import Testing
@testable import MessagesLabHome

/// The Chief rows' v3e fixes: an allowed card's receipt folds into the "Ran" row, failures read
/// as failures with Try Again, a saved note is a transcript row, lines cut at words, the card's
/// command breaks only between words, and the header's band shows while rows lie under it.
@MainActor @Suite struct ChiefNoticeRowsTests {
    typealias Rows = ChiefRowsTests

    static func approval(_ command: String, decided: String?) -> MessagePart {
        .approval(ApprovalRef(request: "perm-1", prompt: "Run `\(command)`?", options: ["Allow", "Deny"], decided: decided))
    }

    static func failure(_ text: String) -> MessagePart {
        .work(WorkRef(session: ChiefRows.failurePrefix + "f1", title: text, status: .failed))
    }

    // MARK: Allowed receipt + Ran row

    @Test func anAllowedCardFoldsIntoTheRanRowItStarted() {
        let items = [Rows.item(1, [Self.approval("cmux tree --all", decided: "Allow")]),
                     Rows.item(2, [Rows.work("t1", "cmux tree --all", .done)])]
        let roles = ChiefRows.roles(items)
        #expect(roles.value(for: IdempotencyKey("k1")) == .head([ChiefRows.ToolCall(id: "t1", title: "cmux tree --all", state: .done,
                                                                                     detail: "cmux tree --all")], allowed: true))
        #expect(roles.value(for: IdempotencyKey("k2")) == .folded)
        let row = Rows.tools(Rows.message(items[0], in: items).parts.first)
        #expect(row?.allowed == true)
        #expect(row.map(ChiefRows.summary) == "Ran cmux tree --all")
        #expect(Rows.message(items[1], in: items).parts.isEmpty)
    }

    @Test func aDeniedOrUnrelatedCardKeepsItsReceipt() {
        let denied = [Rows.item(1, [Self.approval("cmux tree --all", decided: "Deny")]),
                      Rows.item(2, [Rows.work("t1", "cmux tree --all", .done)])]
        #expect(ChiefRows.roles(denied).value(for: IdempotencyKey("k1")) == nil)
        let other = [Rows.item(1, [Self.approval("cmux tree --all", decided: "Allow")]),
                     Rows.item(2, [Rows.work("t1", "git status", .done)])]
        #expect(ChiefRows.roles(other).value(for: IdempotencyKey("k1")) == nil)
        #expect(ChiefRows.roles(other).value(for: IdempotencyKey("k2")) == .head([ChiefRows.ToolCall(id: "t1", title: "git status",
                                                                                                       state: .done, detail: "git status")],
                                                                                   allowed: false))
    }

    @Test func aRunningCallUnderAnAllowedCardUpdatesInPlace() {
        let before = [Rows.item(1, [Self.approval("cmux tree --all", decided: "Allow")]),
                      Rows.item(2, [Rows.work("t1", "cmux tree --all", .running)])]
        let after = [before[0], Rows.item(2, [Rows.work("t1", "cmux tree --all", .done)])]
        let d = HomeDiff.plan(old: before, new: after, oldSummary: Rows.summary, newSummary: Rows.summary, aliases: [:], me: Rows.me)
        #expect(!d.rebuild)
        guard case let .setCustomPart(id, _, part)? = d.actions.first else { Issue.record("no setCustomPart"); return }
        #expect(id == "k1")
        #expect(part.decode(ChiefRows.Tools.self)?.calls.first?.state == .done)
    }

    // MARK: Lines

    @Test func failedCommandsSayFailed() {
        #expect(ChiefRows.lineText(ChiefRows.ToolCall(id: "1", title: "cmux tree --all", state: .failed)) == "Failed cmux tree --all")
    }

    @Test func linesCutAtTheEndOfAWord() {
        let command = Array("cmux chief dispatch --agent codex")
        #expect(ChiefToolRowView.truncated(command, keep: 22) == "cmux chief dispatch…")
        #expect(ChiefToolRowView.truncated(command, keep: 10) == "cmux chief…")
        #expect(ChiefToolRowView.truncated(command, keep: 3) == "cmu…")
        #expect(ChiefToolRowView.truncated(command, keep: 99) == String(command))
    }

    @Test func theCardsCommandBreaksOnlyBetweenWords() {
        #expect(ChiefRows.wrappable("--wait-working /a/b") == "\u{2011}\u{2011}wait\u{2011}working /\u{200B}a/\u{200B}b")
        let a = ChiefRows.Approval(request: "r", prompt: "Run `cmux chief dispatch --wait-working`?", options: ["Allow", "Deny"])
        // Layout only: the command itself (Copy, VoiceOver) keeps its ASCII hyphens.
        #expect(a.command == "cmux chief dispatch --wait-working")
        #expect(ChiefApprovalRowProvider.body(a).string.contains("\u{2011}\u{2011}wait\u{2011}working"))
    }

    @Test func dispatchReadsAsWhatItDid() {
        let command = ##"cmux chief dispatch --agent codex --name "#12: fix login" --cwd /tmp/app -- 'Fix it.'"##
        #expect(ChiefRows.dispatchTitle(command, state: .done) == "Started Codex in “#12: fix login”")
        #expect(ChiefRows.dispatchTitle(command, state: .running) == "Starting Codex in “#12: fix login”")
        #expect(ChiefRows.dispatchTitle("cmux chief dispatch --agent claude -- 'x'", state: .failed) == "Couldn’t start Claude Code")
        #expect(ChiefRows.dispatchTitle("cmux tree --all", state: .done) == nil)
        #expect(ChiefRows.lineText(ChiefRows.ToolCall(id: "1", title: command, state: .done)) == "Started Codex in “#12: fix login”")
    }

    @Test func theCardSaysWhyItAsks() {
        #expect(ChiefRows.reason(for: "cmux chief dispatch --agent codex -- 'x'") == "Starts a coding agent")
        #expect(ChiefRows.reason(for: "cmux vm new --detach") == "Creates a cloud machine")
        #expect(ChiefRows.reason(for: "cmux close-workspace --workspace 2") == "Not in your allowed commands: cmux close-workspace")
    }

    // MARK: Failure and memory rows

    @Test func aFailedTurnIsAnErrorRowWithTryAgainWhileNewest() {
        let items = [Rows.item(1, [.text("show me an error")], by: Rows.me),
                     Rows.item(2, [Self.failure("I couldn’t finish: the socket closed.")])]
        #expect(ChiefRows.roles(items).value(for: IdempotencyKey("k2")) == .failure(retry: true))
        guard case let .custom(c)? = Rows.message(items[1], in: items).parts.first,
              let row = c.decode(ChiefRows.Failure.self) else { Issue.record("no failure row"); return }
        #expect(c.kind == ChiefRows.failureKind)
        #expect(row.retry && row.text == "I couldn’t finish: the socket closed.")
        let later = items + [Rows.item(3, [.text("again")], by: Rows.me)]
        #expect(ChiefRows.roles(later).value(for: IdempotencyKey("k2")) == .failure(retry: false))
        #expect(!ChiefRows.isToolOnly(items[1]))
    }

    @Test func aSavedNoteIsATranscriptRow() {
        let saved = WorkRef(session: ChiefRows.memoryPrefix + "t:m-1a2b3c4d", title: "Prefers 14 pt font", status: .done)
        let item = Rows.item(1, [.work(saved)])
        #expect(!ChiefRows.isToolOnly(item))
        guard case let .custom(c)? = Rows.message(item, in: [item]).parts.first,
              let row = c.decode(ChiefRows.Memory.self) else { Issue.record("no memory row"); return }
        #expect(c.kind == ChiefRows.memoryKind)
        #expect(row.fact == "m-1a2b3c4d" && row.duringTurn && !row.forgotten)
        #expect(ChiefRows.memoryText(row) == "Chief will remember: Prefers 14 pt font")
        let outside = ChiefRows.memory(WorkRef(session: ChiefRows.memoryPrefix + "s:m-1", title: "x", status: .done))
        #expect(outside.map(ChiefRows.memoryText) == "Saved to memory: x")
        let undone = ChiefRows.memory(WorkRef(session: ChiefRows.memoryPrefix + "s:m-1", title: "x", status: .failed))
        #expect(undone.map(ChiefRows.memoryText) == "Removed from memory: x")
    }

    // MARK: Header band

    /// P0-2: the band shows at rest while rows lie under the header, not only on hover.
    @Test func theHeaderBandShowsWhileRowsLieUnderIt() {
        #expect(HostView.headerRevealed(hovered: false, revealsWhenScrolled: true, distanceToTop: 120))
        #expect(!HostView.headerRevealed(hovered: false, revealsWhenScrolled: true, distanceToTop: 0))
        #expect(!HostView.headerRevealed(hovered: false, revealsWhenScrolled: false, distanceToTop: 120))
        #expect(HostView.headerRevealed(hovered: true, revealsWhenScrolled: false, distanceToTop: 0))
        let band = HeaderBackdropView(frame: CGRect(x: 0, y: 0, width: 400, height: 107))
        band.useTopFade(color: .black, maxAlpha: 0.94, solid: 89.0 / 107.0)
        #expect(band.revealOpacity == 0)
        band.setRevealed(true, duration: 0)
        #expect(band.revealOpacity > 0.9)
        #expect(band.topFadeMaxAlpha > 0.9)
        #expect(band.topFade?.locations?.count == 3)
    }
}
