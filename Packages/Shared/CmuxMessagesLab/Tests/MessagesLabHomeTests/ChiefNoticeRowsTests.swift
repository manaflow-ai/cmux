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

    @Test func expandedChildrenShowTheSubjectWithoutRepeatingRan() {
        let command = ChiefRows.ToolCall(id: "1", title: "cmux tree --all", state: .done)
        let dispatch = ChiefRows.ToolCall(id: "2", title: "cmux chief dispatch --agent codex --name Scratch", state: .done)
        #expect(ChiefRows.subject(command) == "cmux tree --all")
        #expect(ChiefRows.subject(dispatch) == "Started Codex in “Scratch”")
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
        // One wording for one event: a note saved outside a turn reads the same.
        #expect(outside.map(ChiefRows.memoryText) == "Chief will remember: x")
        let undone = ChiefRows.memory(WorkRef(session: ChiefRows.memoryPrefix + "s:m-1", title: "x", status: .failed))
        #expect(undone.map(ChiefRows.memoryText) == "Removed from memory: x")
    }

    @Test func aFinishedMemorySaveBesideProseDoesNotCreateAToolRow() {
        let save = Rows.work("t1", "cmux chief memory add \"Prefers 14 pt font\"", .done)
        let item = Rows.item(1, [.text("Got it — I'll remember that."), save])
        let shown = Rows.message(item, in: [item]).parts
        #expect(shown.count == 1)
        guard case let .text(text, _)? = shown.first else {
            Issue.record("completed memory save should leave the acknowledgement bubble")
            return
        }
        #expect(text == "Got it — I'll remember that.")
    }

    // MARK: Header band

    /// P0-2: the band shows at rest while rows lie under the header, not only on hover.
    @Test func theHeaderBandShowsWhileRowsLieUnderIt() {
        #expect(HostView.headerRevealed(hovered: false, revealsWhenScrolled: true, rowsTop: -40, band: 107))
        #expect(!HostView.headerRevealed(hovered: false, revealsWhenScrolled: true, rowsTop: 400, band: 107))
        #expect(!HostView.headerRevealed(hovered: false, revealsWhenScrolled: false, rowsTop: -40, band: 107))
        #expect(HostView.headerRevealed(hovered: true, revealsWhenScrolled: false, rowsTop: 400, band: 107))
        let band = HeaderBackdropView(frame: CGRect(x: 0, y: 0, width: 400, height: 107))
        band.useTopFade(color: .black, maxAlpha: 0.94, solid: 89.0 / 107.0)
        #expect(band.revealOpacity == 0)
        band.setRevealed(true, duration: 0)
        #expect(band.revealOpacity > 0.9)
        #expect(band.topFadeMaxAlpha > 0.9)
        #expect(band.topFade?.locations?.count == 3)
    }

    // MARK: Supervisor round (cloud run)

    static func provisioning(host: String?, name: String?, _ status: WorkRef.Status) -> MessagePart {
        .work(WorkRef(session: ChiefCloudRows.provisionPrefix + "p1", host: host, title: "Create cloud machine", status: status, preview: name))
    }

    /// A collapsed run says what failed and how many: "1 of 4 failed: <cmd>", never only "Used 4 tools ✗".
    @Test func aCollapsedRunSaysWhatFailed() {
        let tools = ChiefRows.Tools(group: "g", calls: [
            ChiefRows.ToolCall(id: "1", title: "cmux tree --all", state: .done),
            ChiefRows.ToolCall(id: "2", title: "cmux vm exec vm-1 -- ls", state: .failed),
            ChiefRows.ToolCall(id: "3", title: "Read README.md", state: .done),
            ChiefRows.ToolCall(id: "4", title: "git status", state: .done),
        ])
        #expect(ChiefRows.summary(tools) == "1 of 4 failed: cmux vm exec vm-1 -- ls")
        var two = tools
        two.calls[3].state = .failed
        #expect(ChiefRows.summary(two) == "2 of 4 failed: cmux vm exec vm-1 -- ls")
        // One call alone: "Failed <cmd>" (the row's red ✗ follows).
        let one = ChiefRows.Tools(group: "g", calls: [ChiefRows.ToolCall(id: "1", title: "cmux tree --all", state: .failed)])
        #expect(ChiefRows.summary(one) == "Failed cmux tree --all")
    }

    /// The provisioning row and the result card name the machine; its raw id is only the tooltip.
    @Test func cloudRowsShowTheMachinesName() {
        let ready = ChiefCloudRows.Provision(id: "p1", state: .done, machine: "vm-794a4009e0b04396", name: "chief-dogfood-1", startedAt: 0)
        #expect(ChiefCloudRows.provisionText(ready, now: Date()) == "Cloud machine ready · chief-dogfood-1")
        let view = ChiefProvisionRowView(frame: .zero)
        view.show(ready)
        #expect(view.toolTip == "vm-794a4009e0b04396")

        let items = [Rows.item(1, [Self.provisioning(host: "vm-794a4009e0b04396", name: "chief-dogfood-1", .done)]),
                     Rows.item(2, [.work(WorkRef(session: "ws_1", host: "vm-794a4009e0b04396", title: "README title", status: .running))])]
        #expect(ChiefRows.roles(items).value(for: IdempotencyKey("k2")) == .cloudResult(name: "chief-dogfood-1"))
        guard case let .custom(c)? = Rows.message(items[1], in: items).parts.first,
              let card = c.decode(ChiefCloudRows.Result.self) else { Issue.record("no result card"); return }
        #expect(card.shownMachine == "chief-dogfood-1" && card.machine == "vm-794a4009e0b04396")
        // Without a provisioning row the card shows the id it has.
        guard case let .custom(alone)? = Rows.message(items[1], in: [items[1]]).parts.first else { Issue.record("no card"); return }
        #expect(alone.decode(ChiefCloudRows.Result.self)?.shownMachine == "vm-794a4009e0b04396")
    }

    /// "Allowed: cmux vm new …" folds into the provisioning row that already says what it did; an allowed
    /// command whose tool row comes back under its receipt is one "Ran … · Allowed" row.
    @Test func allowedReceiptsFoldIntoTheRowsTheyStarted() {
        let new = #"cmux vm new --detach --name "chief-dogfood-1" --size 4g --json"#
        let push = "cmux vm push vm-1 /tmp/repo work/readme-title"
        let items = [Rows.item(1, [Self.provisioning(host: "vm-1", name: "chief-dogfood-1", .done)]),
                     Rows.item(2, [Self.approval(new, decided: "Allow")]),
                     Rows.item(3, [Self.approval(push, decided: "Allow")]),
                     Rows.item(4, [Rows.work("t2", push, .running)])]
        let roles = ChiefRows.roles(items)
        #expect(roles.value(for: IdempotencyKey("k2")) == .folded)
        #expect(Rows.message(items[1], in: items).parts.isEmpty)
        let row = Rows.tools(Rows.message(items[2], in: items).parts.first)
        #expect(row?.allowed == true && row?.calls.map(\.title) == [push])
        #expect(roles.value(for: IdempotencyKey("k4")) == .folded)
        // The card took the row's place until the Allow, which posts the row again right under it.
        let reposted = [Rows.item(7, [Self.approval(new, decided: "Allow")]),
                        Rows.item(8, [Self.provisioning(host: nil, name: "chief-dogfood-1", .running)])]
        #expect(ChiefRows.roles(reposted).value(for: IdempotencyKey("k7")) == .folded)
        // Another author's message in between ends the provisioning stretch: the receipt stays.
        let later = [items[0], Rows.item(5, [.text("ok")], by: Rows.me), Rows.item(6, [Self.approval(new, decided: "Allow")])]
        #expect(ChiefRows.roles(later).value(for: IdempotencyKey("k6")) == nil)
    }

    /// P1-3: the header resolves in the host's appearance (a dark terminal theme in a light app).
    @Test func theHeaderFollowsTheThemesAppearanceNotTheApps() {
        let container = NSView(frame: CGRect(x: 0, y: 0, width: 400, height: 120))
        container.appearance = NSAppearance(named: .aqua)
        let header = PaneHeaderView(frame: container.bounds)
        container.addSubview(header)
        #expect(header.pill.effectiveAppearance.name == .aqua)
        HostView.pinAppearance([header], NSAppearance(named: .darkAqua))
        #expect(header.pill.effectiveAppearance.name == .darkAqua)
        HostView.pinAppearance([header], nil)
        #expect(header.pill.effectiveAppearance.name == .aqua)
    }
}
