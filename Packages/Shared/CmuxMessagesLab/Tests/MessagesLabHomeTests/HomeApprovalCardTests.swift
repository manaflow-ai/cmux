import AppKit
import CmuxAgentQuestion
@testable import CmuxHomeCore
import CmuxHomeRender
import CoreGraphics
import Foundation
import Testing
@testable import MessagesLabHome

/// The Chief's permission approval in Home (2026-10-20: a Home "allow" typed as a reply never
/// reached acpmux, which takes an allow only from the person): a Chief `question` part with a
/// `permission` is a card with Allow and Deny, and a click answers acpmux as the person before it
/// answers the part.
@Suite(.serialized) @MainActor struct HomeApprovalCardTests {
    nonisolated static let headline = "Allow Chief to run `cmux browser right navigate --url https://www.cnn.com`?"
    nonisolated static let reason = "Started from Leo's iPhone: Ask before acting on requests from other devices is on."
    nonisolated static let arguments = "{\n  \"command\": \"cmux browser right navigate --url https://www.cnn.com\"\n}"

    /// The question as optchat-chief's `approval::card` posts it.
    static func approval(harness: AgentQuestion.Harness = .chief, permission: String? = "p1",
                         state: AgentQuestion.State = .pending, preview: String? = arguments) -> AgentQuestion {
        AgentQuestion(id: permission ?? "q", source: .init(harness: harness, session: "s1", permission: permission, agentName: "Chief"),
                      items: [.init(id: "approval", header: "Approval", prompt: headline,
                                    options: [.init(id: "allow", label: "Allow once", detail: reason,
                                                    preview: preview.map { .init(text: $0, format: .monospace) }),
                                              .init(id: "deny", label: "Deny")],
                                    allowsOther: false)],
                      state: state)
    }

    static func card(_ part: Part?) -> HomeApprovalRowProvider.Payload? {
        guard case .custom(let c)? = part, c.kind == HomeApprovalRowProvider.kind else { return nil }
        return HomeApprovalRowProvider.payload(c)
    }

    static let me = ParticipantID("user_local")
    static let chief = ParticipantID("agent_mux")
    /// Another agent in the conversation (a subagent, a teammate's agent): not a Chief.
    static let agent = ParticipantID("agent_scout")

    static func summary() -> ConversationSummary {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let people = [CmuxHomeCore.Participant(id: me, kind: .human, displayName: "Me"),
                      CmuxHomeCore.Participant(id: chief, kind: .agent, displayName: "Chief", agentClass: .chief),
                      CmuxHomeCore.Participant(id: agent, kind: .agent, displayName: "Scout", agentClass: .agent)]
        return ConversationSummary(id: ConversationID("conv_approval"), title: "Chief", participants: people, lastSeq: Seq(1),
                                   createdAt: base, updatedAt: base, readCursors: [:], readCursorTimes: [:])
    }

    /// The question as the transcript shows it, posted by `author` (the Chief by default).
    func mapped(_ question: AgentQuestion, author: ParticipantID = Self.chief, registered: Bool = true) -> Part? {
        if registered { CustomRows.register(HomeApprovalRowProvider.shared) }
        defer { CustomRows.unregister(HomeApprovalRowProvider.kind) }
        let item = TranscriptItem(key: IdempotencyKey("k1"), seq: Seq(1), author: author, parts: [.question(question)],
                                  createdAt: Date(timeIntervalSince1970: 1_800_000_000), delivery: .committed,
                                  messageID: MessageID("msg_1"))
        return HomeMapping.projectedParts(item, summary: Self.summary()).parts.first
    }

    // MARK: Mapping

    @Test func aPendingChiefApprovalIsACardWithButtons() throws {
        let card = try #require(Self.card(mapped(Self.approval())))
        #expect(card.status == .pending)
        #expect(card.session == "s1" && card.permission == "p1")
        #expect(card.prompt == Self.headline)
        #expect(card.header == "Approval" && card.reason == Self.reason && card.preview == Self.arguments)
        #expect(card.allowLabel == "Allow once" && card.denyLabel == "Deny", "the buttons say what the part's options say")
        let layout = HomeApprovalRowProvider.layout(card, width: 300)
        #expect(layout.allow != nil && layout.deny != nil)
        #expect(layout.chip != nil && !layout.reason.isEmpty && layout.preview != nil)
    }

    @Test func anAnsweredOrCancelledApprovalIsOneLine() throws {
        let respondent = AgentQuestionAnswer.Respondent(participant: "user_local", device: "Lawrence's iPhone", isRemote: true)
        let allowed = AgentQuestionAnswer(selections: ["approval": .init(optionIDs: ["allow"])], respondent: respondent)
        let card = try #require(Self.card(mapped(Self.approval(state: .answered(allowed)))))
        #expect(card.status == .allowed && card.device == "Lawrence's iPhone")
        #expect(HomeApprovalRowProvider.layout(card, width: 300).allow == nil)
        #expect(HomeApprovalRowProvider.lineText(card) == CmuxStrings.approvalAllowedOn("Lawrence's iPhone"))

        let denied = AgentQuestionAnswer(selections: ["approval": .init(optionIDs: ["deny"])])
        #expect(try #require(Self.card(mapped(Self.approval(state: .answered(denied))))).status == .denied)
        #expect(try #require(Self.card(mapped(Self.approval(state: .cancelled)))).status == .skipped)
    }

    @Test func anyOtherQuestionStaysText() {
        #expect(Self.card(mapped(Self.approval(harness: .claude))) == nil)
        #expect(Self.card(mapped(Self.approval(permission: nil))) == nil)
        // Without the provider registered, a Chief approval is its text too.
        #expect(Self.card(mapped(Self.approval(), registered: false)) == nil)
    }

    /// Any agent may post a pending question: a look-alike with the Chief's harness and the ids of
    /// its real request, posted by another agent, must not become a card whose Allow answers that
    /// request as the person (review of PR 22639, finding 1).
    @Test func aChiefHarnessQuestionFromAnotherAuthorStaysText() {
        let part = mapped(Self.approval(), author: Self.agent)
        #expect(Self.card(part) == nil)
        guard case .text(let text, _)? = part else { Issue.record("not text: \(String(describing: part))"); return }
        #expect(text.contains("cmux browser right navigate"))
        // A participant the summary does not list (a stranger, a left member) is not a Chief either.
        #expect(Self.card(mapped(Self.approval(), author: ParticipantID("agent_gone"))) == nil)
        #expect(Self.card(mapped(Self.approval(), author: Self.me)) == nil)
    }

    // MARK: Hit test

    @Test func theButtonsHitTestInTheBody() throws {
        let card = try #require(Self.card(mapped(Self.approval())))
        let layout = HomeApprovalRowProvider.layout(card, width: 300)
        let allow = try #require(layout.allow), deny = try #require(layout.deny)
        #expect(HomeApprovalRowProvider.button(at: CGPoint(x: allow.midX, y: allow.midY), card, width: layout.size.width) == true)
        #expect(HomeApprovalRowProvider.button(at: CGPoint(x: deny.midX, y: deny.midY), card, width: layout.size.width) == false)
        // The prompt is not a button.
        #expect(HomeApprovalRowProvider.button(at: CGPoint(x: allow.midX, y: 4), card, width: layout.size.width) == nil)
        // The rects fit the measured card.
        #expect(deny.maxX <= layout.size.width && deny.maxY <= layout.size.height)
    }

    @Test func aRefusalShowsUnderTheButtonsAndTheyStay() throws {
        var card = try #require(Self.card(mapped(Self.approval())))
        let before = HomeApprovalRowProvider.layout(card, width: 300)
        card.error = "The Chief did not accept this app as you"
        let after = HomeApprovalRowProvider.layout(card, width: 300)
        #expect(after.allow == before.allow && after.deny != nil)
        #expect(after.size.height > before.size.height)
        #expect(HomeApprovalRowProvider.lineText(card) == CmuxStrings.approvalRefused("The Chief did not accept this app as you"))
    }

    // MARK: Decision path

    @MainActor final class FakeDecider: HomeApprovalDeciding {
        struct Refused: LocalizedError { var errorDescription: String? { "acpmux said no" } }
        var calls: [(String, String, Bool)] = []
        var chiefs: [String] = []
        var fails = false
        func decide(chief: String, session: String, permission: String, allow: Bool) async throws {
            chiefs.append(chief)
            calls.append((session, permission, allow))
            if fails { throw Refused() }
        }
    }

    /// The rig's conversation with one Chief approval posted; its message id and the store part.
    func posted(_ rig: HomeChatRig) async throws -> MessageID {
        let key = IdempotencyKey.make()
        _ = await rig.source.post(parts: [.question(Self.approval())], from: rig.chief, in: HomeChatRig.conversation, key: key)
        await HomeChatRig.until { rig.store.transcript(for: HomeChatRig.conversation).contains { $0.key == key && $0.seq != nil } }
        let item = try #require(rig.store.transcript(for: HomeChatRig.conversation).first { $0.key == key })
        return try #require(item.messageID)
    }

    func part(_ rig: HomeChatRig, _ message: MessageID) -> AgentQuestion? {
        guard let item = rig.store.transcript(for: HomeChatRig.conversation).first(where: { $0.messageID == message }),
              case .question(let q)? = item.parts.first else { return nil }
        return q
    }

    @Test func anAllowAnswersAcpmuxThenThePart() async throws {
        let rig = try await HomeChatRig(history: 2)
        defer { rig.stop() }
        let decider = FakeDecider()
        rig.view.projection.approvals = decider
        let message = try await posted(rig)
        let result = await rig.view.projection.decideApproval(chief: rig.chief.rawValue, message: message, partIndex: 0, session: "s1", permission: "p1", allow: true)
        #expect((try? result.get()) != nil)
        #expect(decider.calls.count == 1 && decider.calls.first?.2 == true)
        await HomeChatRig.until { part(rig, message)?.isPending == false }
        guard case .answered(let answer)? = part(rig, message)?.state else { Issue.record("not answered"); return }
        #expect(answer.selections["approval"]?.optionIDs == ["allow"])
    }

    @Test func aRefusedAllowAnswersNothing() async throws {
        let rig = try await HomeChatRig(history: 2)
        defer { rig.stop() }
        let decider = FakeDecider()
        decider.fails = true
        rig.view.projection.approvals = decider
        let message = try await posted(rig)
        let result = await rig.view.projection.decideApproval(chief: rig.chief.rawValue, message: message, partIndex: 0, session: "s1", permission: "p1", allow: true)
        #expect(result == .failure(.refused("acpmux said no")))
        rig.frame()
        #expect(part(rig, message)?.isPending == true, "the card takes input again")
    }

    @Test func aRefusedDenyStillAnswersThePart() async throws {
        let rig = try await HomeChatRig(history: 2)
        defer { rig.stop() }
        let decider = FakeDecider()
        decider.fails = true
        rig.view.projection.approvals = decider
        let message = try await posted(rig)
        let result = await rig.view.projection.decideApproval(chief: rig.chief.rawValue, message: message, partIndex: 0, session: "s1", permission: "p1", allow: false)
        #expect((try? result.get()) != nil, "the Chief denies on the card's answer")
        await HomeChatRig.until { part(rig, message)?.isPending == false }
        guard case .answered(let answer)? = part(rig, message)?.state else { Issue.record("not answered"); return }
        #expect(answer.selections["approval"]?.optionIDs == ["deny"])
    }

    /// acpmux allowed but the conversation refused the card's answer: the request is settled, so
    /// the card keeps its buttons off and says so (review finding 9).
    @Test func anAllowTheCardCannotRecordStaysSettled() async throws {
        let rig = try await HomeChatRig(history: 2)
        defer { rig.stop() }
        let decider = FakeDecider()
        rig.view.projection.approvals = decider
        let message = try await posted(rig)
        // The part is no longer pending (answered on another device): `question.answer` is refused.
        let first = await rig.view.projection.decideApproval(chief: rig.chief.rawValue, message: message, partIndex: 0,
                                                             session: "s1", permission: "p1", allow: false)
        #expect((try? first.get()) != nil)
        await HomeChatRig.until { part(rig, message)?.isPending == false }
        let result = await rig.view.projection.decideApproval(chief: rig.chief.rawValue, message: message, partIndex: 0,
                                                              session: "s1", permission: "p1", allow: true)
        #expect(result == .failure(.decidedNotRecorded(allowed: true)))
        let local = HomeApprovalFailure.decidedNotRecorded(allowed: true).local
        #expect(local.busy && local.error == nil && local.note == CmuxStrings.approvalAllowedNotRecorded)
    }

    @Test func theDeciderHearsTheCardsChief() async throws {
        let rig = try await HomeChatRig(history: 2)
        defer { rig.stop() }
        let decider = FakeDecider()
        rig.view.projection.approvals = decider
        let message = try await posted(rig)
        _ = await rig.view.projection.decideApproval(chief: rig.chief.rawValue, message: message, partIndex: 0,
                                                     session: "s1", permission: "p1", allow: true)
        #expect(decider.chiefs == [rig.chief.rawValue])
    }

    @Test func withoutADeciderAllowSaysWhereToAnswer() async throws {
        let rig = try await HomeChatRig(history: 2)
        defer { rig.stop() }
        rig.view.projection.approvals = nil
        let message = try await posted(rig)
        let result = await rig.view.projection.decideApproval(chief: rig.chief.rawValue, message: message, partIndex: 0, session: "s1", permission: "p1", allow: true)
        #expect(result == .failure(.unavailable))
    }

    // MARK: The whole card

    @Test func theHeadlinesCodeSpansAreMonospacedWithoutTheirFences() {
        let (text, code) = HomeApprovalRowProvider.codeSpans(Self.headline)
        #expect(text == "Allow Chief to run cmux browser right navigate --url https://www.cnn.com?")
        #expect(code.count == 1)
        #expect((text as NSString).substring(with: code[0]) == "cmux browser right navigate --url https://www.cnn.com")
        // A longer fence holds a backtick (optchat-chief's code_span pads it with a space).
        let fenced = HomeApprovalRowProvider.codeSpans("Run `` echo `x` ``?")
        #expect(fenced.text == "Run echo `x`?" && fenced.code.count == 1)
        // An unmatched fence stays text.
        #expect(HomeApprovalRowProvider.codeSpans("a ` b").text == "a ` b")
        let layout = HomeApprovalRowProvider.promptLayout(Self.headline, width: 300)
        #expect(layout.runs.contains { $0.style == ["code"] && $0.start == code[0].location && $0.length == code[0].length })
    }

    @Test func theArgumentsBlockShowsAtMostEightLinesAndSaysWhenItIsCut() throws {
        let long = (1...20).map { "  \"line\($0)\": \($0)," }.joined(separator: "\n")
        let card = try #require(Self.card(mapped(Self.approval(preview: long))))
        let layout = HomeApprovalRowProvider.layout(card, width: 380)
        #expect(layout.previewLines.count == HomeApprovalRowProvider.previewMaxLines)
        #expect(layout.previewLines.last?.text.hasSuffix("\u{2026}") == true)
        let short = try #require(Self.card(mapped(Self.approval())))
        let shortLayout = HomeApprovalRowProvider.layout(short, width: 380)
        #expect(shortLayout.previewLines.count >= 3 && shortLayout.previewLines.count < HomeApprovalRowProvider.previewMaxLines)
        #expect(shortLayout.previewLines.allSatisfy { !$0.text.hasSuffix("\u{2026}") })
        // No arguments: no block.
        #expect(HomeApprovalRowProvider.layout(try #require(Self.card(mapped(Self.approval(preview: nil)))), width: 380).preview == nil)
    }

    @Test func theButtonsSitAtTheRightUnderTheArguments() throws {
        let card = try #require(Self.card(mapped(Self.approval())))
        for width in [CGFloat(200), 300, 420, 900] {
            let l = HomeApprovalRowProvider.layout(card, width: width)
            let allow = try #require(l.allow), deny = try #require(l.deny), block = try #require(l.preview)
            #expect(deny.maxX < allow.minX, "Deny, then the primary Allow once")
            #expect(abs(allow.maxX - (l.size.width - Fixture.bubblePadX)) < 1, "right aligned at \(width)")
            #expect(deny.minX >= Fixture.bubblePadX - 0.5 && allow.maxX <= l.size.width)
            #expect(allow.minY >= block.maxY && l.size.height >= allow.maxY)
            #expect(l.size.width <= HomeApprovalRowProvider.maxWidth)
        }
    }

    @Test func anAnsweredCardIsOneLineAsTallAsATextBubble() throws {
        let allowed = AgentQuestionAnswer(selections: ["approval": .init(optionIDs: ["allow"])])
        let card = try #require(Self.card(mapped(Self.approval(state: .answered(allowed)))))
        let l = HomeApprovalRowProvider.layout(card, width: 380)
        #expect(l.size.height == Fixture.lineHeight + 2 * Fixture.bubblePadY)
        let summary = try #require(l.summary)
        #expect(summary.status.text == CmuxStrings.approvalAllowed)
        #expect(summary.rest?.text.contains("cmux browser") == true, "the headline follows, without its fences")
        #expect(summary.rest?.text.contains("`") == false)
        #expect(l.allow == nil && l.preview == nil && l.chip == nil)
    }

    @Test func thePointerDrawsOnlyOnAnEnabledButton() throws {
        var card = try #require(Self.card(mapped(Self.approval())))
        #expect(HomeApprovalRowProvider.buttonState(card, allow: true) == .rest)
        card.pointer = .init(allow: true)
        #expect(HomeApprovalRowProvider.buttonState(card, allow: true) == .hover)
        #expect(HomeApprovalRowProvider.buttonState(card, allow: false) == .rest)
        card.pointer = .init(allow: false, pressed: true)
        #expect(HomeApprovalRowProvider.buttonState(card, allow: false) == .pressed)
        card.busy = true
        #expect(HomeApprovalRowProvider.buttonState(card, allow: false) == .disabled)
        #expect(HomeApprovalRowProvider.buttonState(card, allow: true) == .disabled)
    }

    // MARK: Clicks in the real transcript

    /// The shown approval card (the visible row's own hit: its body rect is where the bitmap
    /// draws), found the way a pointer would.
    func cardHit(_ rig: HomeChatRig) -> MessagesWindowView.Hit? {
        guard let demo = rig.view.controller.demo else { return nil }
        let b = rig.view.controller.host.bounds
        for y in stride(from: b.maxY, to: b.minY, by: -4) {
            for x in stride(from: b.minX, to: b.maxX, by: 8) {
                if let hit = demo.hit(CGPoint(x: x, y: y)), case let .custom(c) = hit.row.part, c.kind == HomeApprovalRowProvider.kind {
                    return hit
                }
            }
        }
        return nil
    }

    /// The card at `ref` as the transcript has it now.
    func shownCard(_ rig: HomeChatRig, _ ref: MessagesLabHome.PartRef) -> HomeApprovalRowProvider.Payload? {
        guard let m = rig.view.controller.store?.state.conversation.messages.last(where: { $0.id == ref.messageId }),
              case let .custom(c)? = m.parts[checked: ref.partIndex] else { return nil }
        return HomeApprovalRowProvider.payload(c)
    }

    /// The center of the card's Allow (`allow`) or Deny in the host's coordinates.
    func center(of hit: MessagesWindowView.Hit, allow: Bool) throws -> CGPoint {
        guard case let .custom(c) = hit.row.part else { throw CardError.notACard }
        let card = try #require(HomeApprovalRowProvider.payload(c))
        let l = HomeApprovalRowProvider.layout(card, width: hit.body.width)
        let r = try #require(allow ? l.allow : l.deny)
        return CGPoint(x: hit.body.minX + r.midX, y: hit.body.minY + r.midY)
    }

    enum CardError: Error { case notACard }

    /// Frames until the posted card shows (a bounded wait: each try lays the transcript out).
    func waitForCard(_ rig: HomeChatRig) async {
        for _ in 0..<200 where cardHit(rig) == nil {
            rig.frame()
            await Task.yield()
        }
    }

    /// A rig whose conversation shows one pending Chief approval for `permission`.
    func shown(permission: String, decider: FakeDecider?) async throws -> (HomeChatRig, MessagesWindowView.Hit) {
        let rig = try await HomeChatRig(history: 2)
        rig.view.projection.approvals = decider
        let key = IdempotencyKey.make()
        _ = await rig.source.post(parts: [.question(Self.approval(permission: permission))], from: rig.chief,
                                  in: HomeChatRig.conversation, key: key)
        await waitForCard(rig)
        guard let hit = cardHit(rig) else { rig.stop(); throw CardError.notACard }
        return (rig, hit)
    }

    /// The regression (PR 22639 dogfood, "the buttons don't work"): a click on Allow in the
    /// conversation itself, not a thread view, never reached the card: `ChatController.clicked`
    /// only focused the message box.
    @Test func aClickOnAllowInTheTranscriptDecides() async throws {
        let decider = FakeDecider()
        let (rig, hit) = try await shown(permission: "p-click-allow", decider: decider)
        defer { rig.stop() }
        // The drawn card and the hit rects share one layout at the row's real body geometry.
        guard case let .custom(c) = hit.row.part, let card = HomeApprovalRowProvider.payload(c) else { Issue.record("not a card"); return }
        let measured = HomeApprovalRowProvider.layout(card, width: hit.body.width)
        #expect(abs(measured.size.height - hit.body.height) <= 1, "measured \(measured.size) body \(hit.body)")
        rig.view.controller.clicked(try center(of: hit, allow: true))
        await HomeChatRig.until { decider.calls.count == 1 }
        #expect(decider.calls.first?.0 == "s1" && decider.calls.first?.1 == "p-click-allow" && decider.calls.first?.2 == true)
    }

    @Test func aClickOnDenyInTheTranscriptDecides() async throws {
        let decider = FakeDecider()
        let (rig, hit) = try await shown(permission: "p-click-deny", decider: decider)
        defer { rig.stop() }
        rig.view.controller.clicked(try center(of: hit, allow: false))
        await HomeChatRig.until { decider.calls.count == 1 }
        #expect(decider.calls.first?.2 == false)
    }

    /// The press and the release through the mouse path: the press draws the pressed button and
    /// starts no selection; the release on it clicks; a second click while the first is in flight
    /// does nothing.
    @Test func aPressAndReleaseOnAButtonClicksItOnce() async throws {
        let decider = FakeDecider()
        let (rig, hit) = try await shown(permission: "p-press", decider: decider)
        defer { rig.stop() }
        let controller = rig.view.controller
        let p = try center(of: hit, allow: true)
        controller.approvalPointerMoved(p)
        #expect(shownCard(rig, hit.row.ref)?.pointer == .init(allow: true, pressed: false), "hover")
        #expect(controller.approvalPressBegan(at: p))
        #expect(shownCard(rig, hit.row.ref)?.pointer == .init(allow: true, pressed: true), "press")
        #expect(controller.approvalPressEnded(at: p))
        #expect(shownCard(rig, hit.row.ref)?.busy == true, "in flight: the buttons are off")
        controller.clicked(p)
        await HomeChatRig.until { decider.calls.count == 1 }
        for _ in 0..<50 { await Task.yield() }
        #expect(decider.calls.count == 1, "one decision")
    }

    @Test func aReleaseOffThePressedButtonDoesNothing() async throws {
        let decider = FakeDecider()
        let (rig, hit) = try await shown(permission: "p-release-off", decider: decider)
        defer { rig.stop() }
        let controller = rig.view.controller
        #expect(controller.approvalPressBegan(at: try center(of: hit, allow: true)))
        #expect(controller.approvalPressEnded(at: try center(of: hit, allow: false)))
        for _ in 0..<50 { await Task.yield() }
        #expect(decider.calls.isEmpty)
        #expect(shownCard(rig, hit.row.ref)?.pointer == .init(allow: false), "the pointer now hovers Deny")
        controller.approvalPointerMoved(nil)
        #expect(shownCard(rig, hit.row.ref)?.pointer == nil)
    }

    /// A mouse event at `p` in the rig's window (the controller reads only its click count and number).
    func mouse(_ type: NSEvent.EventType, _ p: CGPoint, _ rig: HomeChatRig) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: 0,
                                        windowNumber: rig.window.windowNumber, context: nil, eventNumber: 0,
                                        clickCount: 1, pressure: 1))
    }

    /// A point on the card off its buttons (its headline, top left).
    func offTheButtons(_ rig: HomeChatRig, _ hit: MessagesWindowView.Hit) throws -> CGPoint {
        let p = CGPoint(x: hit.body.minX + 12, y: hit.body.minY + 10)
        try #require(rig.view.controller.demo?.hit(p) != nil)
        try #require(!rig.view.controller.onApprovalButton(at: p))
        return p
    }

    /// Through the mouse path: a press and a release on Allow decide; this is what the next two
    /// tests take away.
    @Test func aMousePressAndReleaseOnAllowDecide() async throws {
        let decider = FakeDecider()
        let (rig, hit) = try await shown(permission: "p-mouse", decider: decider)
        defer { rig.stop() }
        let controller = rig.view.controller
        let p = try center(of: hit, allow: true)
        controller.mouseDown(at: p, try mouse(.leftMouseDown, p, rig))
        controller.mouseUp(at: p, try mouse(.leftMouseUp, p, rig))
        await HomeChatRig.until { decider.calls.count == 1 }
        #expect(decider.calls.first?.2 == true)
    }

    /// Review of 44ba8784: a release on Allow after a press elsewhere went through `clicked` and
    /// approved. A button clicks only when pressed and released on it.
    @Test func aReleaseOnAButtonWhosePressBeganElsewhereClicksNothing() async throws {
        let decider = FakeDecider()
        let (rig, hit) = try await shown(permission: "p-press-elsewhere", decider: decider)
        defer { rig.stop() }
        let controller = rig.view.controller
        let off = try offTheButtons(rig, hit)
        let allow = try center(of: hit, allow: true)
        controller.mouseDown(at: off, try mouse(.leftMouseDown, off, rig))
        controller.mouseUp(at: allow, try mouse(.leftMouseUp, allow, rig))
        for _ in 0..<50 { await Task.yield() }
        #expect(decider.calls.isEmpty)
        #expect(shownCard(rig, hit.row.ref)?.busy != true, "nothing in flight")
    }

    /// Review of 44ba8784: with the tapback picker open, a press on a card's button took the press
    /// and its release approved. That press only closes the picker.
    @Test func withThePickerOpenAPressOnAButtonOnlyClosesThePicker() async throws {
        let decider = FakeDecider()
        let (rig, hit) = try await shown(permission: "p-picker", decider: decider)
        defer { rig.stop() }
        let controller = rig.view.controller
        controller.showPicker(for: hit)
        try #require(controller.picker != nil)
        let allow = try center(of: hit, allow: true)
        controller.mouseDown(at: allow, try mouse(.leftMouseDown, allow, rig))
        #expect(controller.approvalPress == nil, "the card took no press")
        controller.mouseUp(at: allow, try mouse(.leftMouseUp, allow, rig))
        for _ in 0..<50 { await Task.yield() }
        #expect(decider.calls.isEmpty)
        #expect(controller.picker == nil, "the picker closed")
    }

    // MARK: Every click that cannot decide says why

    /// The click's provider is gone (no card here any more): the click shows why on the card.
    @Test func aClickThatCannotStartShowsWhyOnTheCard() async throws {
        let decider = FakeDecider()
        let (rig, hit) = try await shown(permission: "p-unregistered", decider: decider)
        defer { rig.stop() }
        CustomRows.unregister(HomeApprovalRowProvider.kind)
        defer {
            CustomRows.register(HomeApprovalRowProvider.shared)
            HomeApprovalRowProvider.shared.setLocal(HomeApprovalRowProvider.key(session: "s1", permission: "p-unregistered"), .init())
        }
        rig.view.controller.clicked(try center(of: hit, allow: true))
        #expect(shownCard(rig, hit.row.ref)?.error == CmuxStrings.approvalUnavailable)
        #expect(HomeApprovalRowProvider.shared.local(HomeApprovalRowProvider.key(session: "s1", permission: "p-unregistered")).error
            == CmuxStrings.approvalUnavailable, "a rebuild keeps it")
        #expect(decider.calls.isEmpty)
    }

    @Test func aCardNoPaneShowsIsNotShownAndTheClickSaysSo() async throws {
        let rig = try await HomeChatRig(history: 2)
        defer { rig.stop() }
        let ref = MessagesLabHome.PartRef(messageId: "msg_not_here", partIndex: 0)
        #expect(rig.view.projection.decideApproval(ref, allow: true) == .notShown)
        var payload = HomeApprovalRowProvider.Payload(session: "s1", permission: "p-not-shown", prompt: "x", status: .pending)
        payload.busy = false
        let part = try #require(HomeApprovalRowProvider.custom(payload))
        defer { HomeApprovalRowProvider.shared.setLocal(HomeApprovalRowProvider.key(payload), .init()) }
        #expect(HomeApprovalRowProvider.shared.click(part, ref: ref, allow: true) == CmuxStrings.approvalUnavailable)
        #expect(HomeApprovalRowProvider.shared.local(HomeApprovalRowProvider.key(payload)).error == CmuxStrings.approvalUnavailable)
    }

    @Test func aLookAlikeFromAnotherAuthorIsRefused() async throws {
        let rig = try await HomeChatRig(history: 2)
        defer { rig.stop() }
        let key = IdempotencyKey.make()
        _ = await rig.source.post(parts: [.question(Self.approval(permission: "p-me"))], from: rig.me, in: HomeChatRig.conversation, key: key)
        await HomeChatRig.until { rig.store.transcript(for: HomeChatRig.conversation).contains { $0.key == key && $0.seq != nil } }
        rig.frame()
        func isPrompt(_ part: Part) -> Bool {
            guard case let .text(t, _) = part else { return false }
            return t.contains("cmux browser right navigate")
        }
        let message = try #require(rig.view.controller.store?.state.conversation.messages.last { $0.parts.contains(where: isPrompt) })
        let index = try #require(message.parts.firstIndex(where: isPrompt))
        #expect(rig.view.projection.decideApproval(MessagesLabHome.PartRef(messageId: message.id, partIndex: index), allow: true)
            == .refused(CmuxStrings.approvalNotChief))
    }

    @Test func aCardAnsweredMeanwhileIsRefusedAsNoLongerOpen() async throws {
        let rig = try await HomeChatRig(history: 2)
        defer { rig.stop() }
        let decider = FakeDecider()
        rig.view.projection.approvals = decider
        let allowed = AgentQuestionAnswer(selections: ["approval": .init(optionIDs: ["allow"])])
        let key = IdempotencyKey.make()
        _ = await rig.source.post(parts: [.question(Self.approval(permission: "p-answered", state: .answered(allowed)))],
                                  from: rig.chief, in: HomeChatRig.conversation, key: key)
        await waitForCard(rig)
        let hit = try #require(cardHit(rig))
        #expect(rig.view.projection.decideApproval(hit.row.ref, allow: true) == .refused(CmuxStrings.approvalStale))
        #expect(decider.calls.isEmpty)
    }

    @Test func aClickWhileADecisionIsInFlightChangesNothing() async throws {
        let decider = FakeDecider()
        let (rig, hit) = try await shown(permission: "p-busy", decider: decider)
        defer { rig.stop() }
        let key = HomeApprovalRowProvider.key(session: "s1", permission: "p-busy")
        HomeApprovalRowProvider.shared.setLocal(key, .init(busy: true))
        defer { HomeApprovalRowProvider.shared.setLocal(key, .init()) }
        #expect(rig.view.projection.decideApproval(hit.row.ref, allow: true) == .inFlight)
        for _ in 0..<50 { await Task.yield() }
        #expect(decider.calls.isEmpty)
    }

    @Test func withoutTheProviderInstalledAClickIsRefused() async throws {
        let (rig, hit) = try await shown(permission: "p-uninstalled", decider: FakeDecider())
        defer { rig.stop() }
        CustomRows.unregister(HomeApprovalRowProvider.kind)
        defer { CustomRows.register(HomeApprovalRowProvider.shared) }
        #expect(rig.view.projection.decideApproval(hit.row.ref, allow: true) == .refused(CmuxStrings.approvalUnavailable))
    }
}

extension Result where Success == Void, Failure == HomeApprovalFailure {
    static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case (.success, .success): true
        case (.failure(let a), .failure(let b)): a == b
        default: false
        }
    }
}
