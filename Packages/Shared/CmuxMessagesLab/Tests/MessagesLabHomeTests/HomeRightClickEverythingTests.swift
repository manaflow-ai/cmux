import AppKit
@testable import CmuxHomeCore
import Foundation
import Testing
@testable import MessagesLabHome

/// The user, 2026-10-25: "make sure I can right click reply images, my own images, literally
/// everything" in the Chief's Home chat. Every content type has a right-click menu built by one
/// builder (``HomeContentMenu``): a link in text or a link card (Open Link, Copy Link Address),
/// the selected words (Copy copies the selection), a quoted reply's picture (the reply preview
/// above a reply), and a picture in the message box.
@MainActor @Suite(.serialized) struct HomeRightClickEverythingTests {
    final class NoWake: ChatWakeScheduler {
        func schedule(after seconds: Double, _ action: @escaping @MainActor @Sendable () -> Void) {}
        func cancel() {}
    }

    static let device = "https://github.com/login/device"
    static let me = ParticipantID("user_me"), chief = ParticipantID("agent_chief")

    private func controller(_ items: [TranscriptItem]) -> (NSWindow, ChatController) {
        _ = NSApplication.shared
        HomeMarkdownPolicy.install()
        let people = [CmuxHomeCore.Participant(id: Self.me, kind: .human, displayName: "Me"),
                      CmuxHomeCore.Participant(id: Self.chief, kind: .agent, displayName: "Chief", agentClass: .chief)]
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let id = ConversationID("conv_rightclick")
        let summary = ConversationSummary(id: id, title: "Chief", participants: people, lastSeq: Seq(items.count),
                                          createdAt: base, updatedAt: base, readCursors: [:], readCursorTimes: [:])
        var core = ProjectionCore(me: Self.me)
        let (conv, w) = core.install(id, items: items, summary: summary)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 700), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let controller = ChatController(host: HostView(frame: NSRect(x: 0, y: 0, width: 600, height: 700)), wake: NoWake())
        window.contentView = controller.host
        controller.install(conv, windowStart: w.start, total: w.total)
        controller.host.layoutSubtreeIfNeeded()
        controller.demo?.layoutIfNeeded()
        controller.demo?.collection.layoutIfNeeded()
        return (window, controller)
    }

    private func item(_ n: Int, _ author: ParticipantID, _ parts: [MessagePart], replyTo: CmuxHomeCore.PartRef? = nil, threadRoot: MessageID? = nil) -> TranscriptItem {
        TranscriptItem(key: IdempotencyKey("k\(n)"), seq: Seq(n), author: author, parts: parts,
                       createdAt: Date(timeIntervalSince1970: 1_800_000_000 + Double(n)), delivery: .committed,
                       replyTo: replyTo, threadRoot: threadRoot, messageID: MessageID("msg_\(n)"))
    }

    private func titles(_ menu: NSMenu?) -> [String] {
        (menu?.items ?? []).map { ($0 as? MenuAction)?.label ?? $0.title }
    }

    @Test func aLinkInTextOffersOpenLinkAndCopyLinkAddress() throws {
        let (window, controller) = controller([item(1, Self.chief, [.text("Open **\(Self.device)** and approve.")])])
        defer { window.close() }
        let b = controller.host.bounds
        var found: CGPoint?
        search: for y in stride(from: b.minY, to: b.maxY, by: 2) {
            for x in stride(from: b.minX, to: b.maxX, by: 2) where controller.linkURL(at: CGPoint(x: x, y: y))?.absoluteString == Self.device {
                found = CGPoint(x: x, y: y); break search
            }
        }
        let p = try #require(found)
        let menu = controller.menu(at: p)
        controller.menuHighlight?.discard(); controller.menuHighlight = nil
        let shown = titles(menu)
        #expect(shown.contains(CmuxStrings.openLink), "\(shown)")
        #expect(shown.contains(CmuxStrings.copyLinkAddress), "\(shown)")
    }

    @Test func copyCopiesTheSelectionWhenThereIsOne() {
        var written: [String] = []
        let menu = HomeContentMenu(writeString: { written.append($0) })
        for (selection, expected) in [("green", "green"), (nil, "The build is green."), ("", "The build is green.")] {
            let rows = menu.textItems("The build is green.", selection: selection)
            let copy = rows.first { ($0 as? MenuAction)?.label == Strings.menuCopy }
            if let copy, let action = copy.action { NSApp.sendAction(action, to: copy.target, from: copy) }
            #expect(written.last == expected)
        }
    }

    @Test func linkRowsCopyTheAddressAndOpenIt() throws {
        var written: [String] = [], opened: [URL] = []
        let menu = HomeContentMenu(writeString: { written.append($0) }, openLink: { opened.append($0) })
        let url = try #require(URL(string: Self.device))
        let rows = menu.linkItems(url)
        #expect(rows.map { ($0 as? MenuAction)?.label } == [CmuxStrings.openLink, CmuxStrings.copyLinkAddress])
        for row in rows { if let a = row.action { NSApp.sendAction(a, to: row.target, from: row) } }
        #expect(opened == [url])
        #expect(written == [Self.device])
    }

    @Test func aQuotedReplyPictureHasTheAttachmentMenu() throws {
        let png = AttachmentRef(hash: "h1", name: "shot.png", mimeType: "image/png", byteCount: 10, width: 400, height: 300)
        let items = [
            item(1, Self.me, [.attachment(png)]),
            item(2, Self.chief, [.text("Looking at it now.")]),
            item(3, Self.me, [.text("Is the second button cut off?")], replyTo: CmuxHomeCore.PartRef(message: MessageID("msg_1"), partIndex: 0), threadRoot: MessageID("msg_1")),
        ]
        let (window, controller) = controller(items)
        defer { window.close() }
        let demo = try #require(controller.demo as MessagesWindowView?)
        var centre: CGPoint?
        for case let cell as RowCell in demo.collection.visibleCells {
            guard let spec = cell.spec, case let .threadPreview(pv) = spec.kind else { continue }
            let r = cell.convert(cell.bounds, to: demo)
            centre = CGPoint(x: pv.outgoing ? r.minX + spec.metrics.rightEdge - 20 : r.minX + Fixture.leftEdge + 20, y: r.midY)
        }
        let p = try #require(centre, "the reply shows no quoted picture")
        let menu = controller.menu(at: p)
        controller.menuHighlight?.discard(); controller.menuHighlight = nil
        let shown = titles(menu)
        #expect(shown.contains(Strings.menuCopy), "\(shown)")
        #expect(shown.contains(CmuxStrings.saveAttachmentAs), "\(shown)")
    }

    private func rightClick() -> NSEvent {
        NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                           context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }

    @Test func aPictureInTheMessageBoxHasCopySaveAsAndRemove() {
        let a = MessagesLabHome.Attachment(id: "p1", kind: "image", fileName: "p1.png", mimeType: "image/png", byteSize: 1,
                                           asset: nil, poster: nil, width: 40, height: 30, durationSeconds: nil, transfer: .done)
        let attachment = ComposeInlineAttachment(a, scale: 2)
        let view = ComposeInlineAttachmentView(attachment)
        defer { withExtendedLifetime(attachment) {} }
        let shown = titles(view.menu(for: rightClick()))
        #expect(shown.contains(Strings.menuCopy), "\(shown)")
        #expect(shown.contains(CmuxStrings.saveAttachmentAs), "\(shown)")
        #expect(shown.contains(CmuxStrings.removeAttachment), "\(shown)")
    }

    @Test func theReplyCardOnTheMessageBoxCopiesTheQuote() {
        let card = ReplyQuoteCardView()
        let shown = titles(card.menu(for: rightClick()))
        #expect(shown == [Strings.menuCopy, "", CmuxStrings.replyQuoteRemove], "\(shown)")
    }
}
