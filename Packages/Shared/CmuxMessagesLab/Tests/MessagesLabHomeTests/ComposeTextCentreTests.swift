import AppKit
import CmuxHomeCore
import CmuxHomeRender
import Testing
@testable import MessagesLabHome

/// #48467, the person, about the Chief's message field: "is it just me or is this not perfectly vertically aligned?"
/// The typed line, the caret and the placeholder sat about 1 pt under the field's centre, where the "+", the mic and
/// the send button are centred. Drives a real `ChatController` in an offscreen window and measures the line AppKit
/// lays out, not the constants.
@MainActor @Suite(.serialized) struct ComposeTextCentreTests {
    final class NoWake: ChatWakeScheduler {
        func schedule(after seconds: Double, _ action: @escaping @MainActor @Sendable () -> Void) {}
        func cancel() {}
    }

    static let me = ParticipantID("user_me")
    static let them = ParticipantID("agent_chief")

    private func controller() -> (NSWindow, ChatController) {
        let people = [CmuxHomeCore.Participant(id: Self.me, kind: .human, displayName: "Me"),
                      CmuxHomeCore.Participant(id: Self.them, kind: .agent, displayName: "Chief", agentClass: .chief)]
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let items = [TranscriptItem(key: IdempotencyKey("k1"), seq: Seq(1), author: Self.them, parts: [.text("Hello")],
                                    createdAt: base, delivery: .committed, messageID: MessageID("msg_1"))]
        let summary = ConversationSummary(id: ConversationID("conv_centre"), title: "Chief", participants: people, lastSeq: 1,
                                          createdAt: base, updatedAt: base, readCursors: [:], readCursorTimes: [:])
        var core = ProjectionCore(me: Self.me)
        let (conv, w) = core.install(ConversationID("conv_centre"), items: items, summary: summary)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 700), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let controller = ChatController(host: HostView(frame: NSRect(x: 0, y: 0, width: 600, height: 700)), wake: NoWake())
        window.contentView = controller.host
        controller.install(conv, windowStart: w.start, total: w.total)
        controller.host.layoutSubtreeIfNeeded()
        controller.bringWindowForward = { _ in }
        window.makeFirstResponder(controller.demo!.compose.textView.view)
        return (window, controller)
    }

    /// The first line's baseline in the field's coordinates (those of `fieldRect`), from the layout AppKit made.
    private func firstBaseline(_ compose: ComposeView) throws -> CGFloat {
        let field = compose.textView.view
        let tlm = try #require(field.textLayoutManager)
        tlm.ensureLayout(for: tlm.documentRange)
        var baseline: CGFloat?
        tlm.enumerateTextLayoutFragments(from: tlm.documentRange.location, options: [.ensuresLayout]) { fragment in
            if let line = fragment.textLineFragments.first {
                baseline = fragment.layoutFragmentFrame.minY + line.typographicBounds.minY + line.glyphOrigin.y
            }
            return false
        }
        let local = try #require(baseline) + field.textContainerOrigin.y
        let space = try #require(compose.textView.clip.superview)
        return field.convert(NSPoint(x: 0, y: local), to: space).y
    }

    /// The caret at the end of the draft, in the field's coordinates.
    private func caret(_ compose: ComposeView) throws -> CGRect {
        let field = compose.textView.view
        let rect = try #require(field.caretRects(at: [field.string.utf16.count]).kept.first ?? nil)
        let space = try #require(compose.textView.clip.superview)
        return field.convert(rect, to: space)
    }

    /// One line: its optical centre (half way between the capitals' and the lowercase letters' centres) and the caret's
    /// centre are on the field's centre, where the "+" and the mic are, within half a point.
    @Test func theTypedLineAndCaretAreCentredInTheField() throws {
        let (window, controller) = controller()
        defer { window.close() }
        let compose = controller.demo!.compose
        compose.textView.insertText("asdadasdadfadAasdfaAAAAA")
        controller.host.layoutSubtreeIfNeeded()
        let f = compose.fieldRect
        #expect(abs(f.height - ComposeMetrics.oneLine) < 0.5, "not one line: \(f)")
        let baseline = try firstBaseline(compose)
        let optical = baseline - ComposeTextCentre.opticalCentreAboveBaseline(ComposeView.font)
        let caret = try caret(compose)
        print("COMPOSE_CENTRE|field=\(f)|baseline=\(baseline - f.minY)|optical=\(optical - f.minY)|caret=\(caret.minY - f.minY)-\(caret.maxY - f.minY)|plus=\(compose.plusRect.midY - f.minY)|lift=\(ComposeTextCentre.textLift)|caretLift=\(ComposeTextCentre.caretLift)")
        #expect(abs(optical - f.midY) <= 0.5, "the line's optical centre is \(optical - f.midY) pt off the field's centre")
        #expect(abs(caret.midY - f.midY) <= 0.5, "the caret's centre is \(caret.midY - f.midY) pt off the field's centre")
        #expect(abs(compose.plusRect.midY - f.midY) <= 0.5, "the + is off the field's centre")
        // The placeholder draws its baseline where the typed line's is.
        #expect(abs(ComposeView.firstBaseline - ComposeTextCentre.textLift - (baseline - f.minY)) <= 0.75,
                "the placeholder's baseline is off the typed line's")
    }

    /// More lines: the field grows by a line each, and the first line stays where it was under the field's top.
    @Test func growthKeepsTheFirstLineInPlace() throws {
        let (window, controller) = controller()
        defer { window.close() }
        let compose = controller.demo!.compose
        compose.textView.insertText("First line")
        controller.host.layoutSubtreeIfNeeded()
        let one = compose.fieldRect, oneBaseline = try firstBaseline(compose) - one.minY
        compose.textView.insertText("\nSecond line\nThird line")
        controller.host.layoutSubtreeIfNeeded()
        let three = compose.fieldRect, threeBaseline = try firstBaseline(compose) - three.minY
        #expect(abs(three.height - one.height - 2 * Fixture.lineHeight) <= 0.5, "the field grew \(three.height - one.height) pt for two lines")
        #expect(abs(threeBaseline - oneBaseline) <= 0.5, "the first line moved \(threeBaseline - oneBaseline) pt as the field grew")
        let caret = try caret(compose)
        #expect(caret.maxY <= three.maxY && caret.minY >= three.minY, "the caret \(caret) is outside the field \(three)")
    }
}
