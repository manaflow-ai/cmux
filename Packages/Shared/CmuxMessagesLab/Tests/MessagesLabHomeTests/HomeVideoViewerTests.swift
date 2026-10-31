import AppKit
@testable import CmuxHomeCore
import CmuxHomeRender
import Foundation
import Testing
@testable import MessagesLabHome

/// The user, 2026-10-30: "we need to drastically improve the video UI in chief … i want to double
/// click it and see it bigger". A double-click on a video bubble opens the large viewer; a single
/// click still plays it in place; a double-click on a picture does not open a video.
@MainActor @Suite(.serialized) struct HomeVideoViewerTests {
    final class NoWake: ChatWakeScheduler {
        func schedule(after seconds: Double, _ action: @escaping @MainActor @Sendable () -> Void) {}
        func cancel() {}
    }

    /// Records what the clicks asked for.
    final class Recorder: ChatIntents {
        var opened: [ID] = []
        var toggled: [ID] = []
        var state: HomeVideoState = .poster
        func threadMovedByUser() {}
        func messageLink(_ id: ID) -> String? { nil }
        func send() -> String? { nil }
        func react(_ ref: MessagesLabHome.PartRef, _ kind: MessagesLabHome.Reaction.Kind) {}
        var canReact: Bool { false }
        var canReply: Bool { false }
        func pickAttachments() {}
        func takeAttachments(from pasteboard: NSPasteboard) -> Bool { false }
        func acceptsAttachments(from pasteboard: NSPasteboard) -> Bool { false }
        func statusLineClicked(_ rect: CGRect, in view: NSView) {}
        func draftChanged() {}
        func linkTapped(_ ref: MessagesLabHome.PartRef, url: String) {}
        func canCancelSend(_ message: ID) -> Bool { false }
        func cancelSend(_ message: ID) {}
        func canRetrySend(_ message: ID) -> Bool { false }
        func retrySend(_ message: ID) {}
        func deleteFailedSend(_ message: ID) {}
        func openAttachment(_ message: ID, _ attachment: ID) {}
        func toggleVideo(_ ref: MessagesLabHome.PartRef, _ attachment: ID) { toggled.append(attachment) }
        func videoState(_ ref: MessagesLabHome.PartRef) -> HomeVideoState { state }
        func openVideo(_ ref: MessagesLabHome.PartRef, _ attachment: ID) { opened.append(attachment) }
        func scrolled() {}
        func rowsPlaced() {}
    }

    struct Pane {
        let window: NSWindow
        let controller: ChatController
        let recorder: Recorder
    }

    private func pane(_ attachment: AttachmentRef) -> Pane {
        let me = ParticipantID("user_me"), chief = ParticipantID("agent_chief")
        let people = [CmuxHomeCore.Participant(id: me, kind: .human, displayName: "Me"),
                      CmuxHomeCore.Participant(id: chief, kind: .agent, displayName: "Chief", agentClass: .chief)]
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let items = [
            TranscriptItem(key: IdempotencyKey("k1"), seq: Seq(1), author: chief, parts: [.text("Here is the recording.")],
                           createdAt: base, delivery: .committed, messageID: MessageID("msg_1")),
            TranscriptItem(key: IdempotencyKey("k2"), seq: Seq(2), author: chief, parts: [.attachment(attachment)],
                           createdAt: base.addingTimeInterval(1), delivery: .committed, messageID: MessageID("msg_2")),
        ]
        let summary = ConversationSummary(id: ConversationID("conv_video"), title: "Chief", participants: people, lastSeq: 2,
                                          createdAt: base, updatedAt: base, readCursors: [:], readCursorTimes: [:])
        var core = ProjectionCore(me: me)
        let (conv, w) = core.install(ConversationID("conv_video"), items: items, summary: summary)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 700), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let controller = ChatController(host: HostView(frame: NSRect(x: 0, y: 0, width: 600, height: 700)), wake: NoWake())
        window.contentView = controller.host
        controller.install(conv, windowStart: w.start, total: w.total)
        controller.host.layoutSubtreeIfNeeded()
        controller.demo?.layoutIfNeeded()
        controller.demo?.collection.layoutIfNeeded()
        let recorder = Recorder()
        controller.intents = recorder
        return Pane(window: window, controller: controller, recorder: recorder)
    }

    static let video = AttachmentRef(hash: "hash_clip", name: "clip.mp4", mimeType: "video/mp4", byteCount: 9_000, width: 640, height: 400)
    static let picture = AttachmentRef(hash: "hash_shot", name: "shot.png", mimeType: "image/png", byteCount: 1_234, width: 400, height: 300)

    /// The middle of the attachment bubble, and the bubble's frame.
    private func attachment(in controller: ChatController) -> (point: CGPoint, body: CGRect)? {
        let b = controller.host.bounds
        for y in stride(from: b.minY + 60, to: b.maxY - 80, by: 4) {
            for x in stride(from: b.minX, to: b.maxX, by: 4) {
                let p = CGPoint(x: x, y: y)
                if let hit = controller.demo?.hit(p), case .attachment = hit.row.part {
                    return (CGPoint(x: hit.body.midX, y: hit.body.midY), hit.body)
                }
            }
        }
        return nil
    }

    private func event(_ type: NSEvent.EventType, _ p: CGPoint, clicks: Int, in window: NSWindow) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                           context: nil, eventNumber: 0, clickCount: clicks, pressure: 1)!
    }

    /// A press and release with `clicks` as AppKit counts them.
    private func click(_ p: CGPoint, clicks: Int, in pane: Pane) {
        pane.controller.mouseDown(at: p, event(.leftMouseDown, p, clicks: clicks, in: pane.window))
        pane.controller.mouseUp(at: p, event(.leftMouseUp, p, clicks: clicks, in: pane.window))
    }

    @Test func aDoubleClickOnAVideoOpensTheLargeViewer() throws {
        let pane = pane(Self.video)
        let p = try #require(attachment(in: pane.controller)).point
        click(p, clicks: 1, in: pane)
        click(p, clicks: 2, in: pane)
        #expect(pane.recorder.opened == [Self.video.hash])
        // The first click of the pair played it in place; the second opened it, it did not toggle again.
        #expect(pane.recorder.toggled == [Self.video.hash])
        withExtendedLifetime(pane.window) {}
    }

    @Test func aSingleClickOnAVideoStillPlaysItInPlace() throws {
        let pane = pane(Self.video)
        let p = try #require(attachment(in: pane.controller)).point
        click(p, clicks: 1, in: pane)
        #expect(pane.recorder.toggled == [Self.video.hash])
        #expect(pane.recorder.opened.isEmpty)
        withExtendedLifetime(pane.window) {}
    }

    @Test func aDoubleClickOnAPictureOpensNoVideo() throws {
        let pane = pane(Self.picture)
        let p = try #require(attachment(in: pane.controller)).point
        click(p, clicks: 1, in: pane)
        click(p, clicks: 2, in: pane)
        #expect(pane.recorder.opened.isEmpty)
        withExtendedLifetime(pane.window) {}
    }
}
