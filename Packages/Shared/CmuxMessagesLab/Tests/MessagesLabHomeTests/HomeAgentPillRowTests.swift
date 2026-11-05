import AppKit
import CmuxHomeCore
import CoreGraphics
import Foundation
import Testing
@testable import MessagesLabHome

/// The shipped agents row (user 2026-11-03, msg 19960): one pill per agent, ChatGPT's look, with the
/// agent's title and its state, as tall as its pills, drawn with ink in each pill.
@MainActor @Suite(.serialized) struct HomeAgentPillRowTests {
    static func row() -> HomeAgentMessageRow {
        var row = HomeAgentMessageRow(group: "0123456789abcdef", kind: .fold(count: 5, peers: ["a959", "a931", "a933"], expanded: false))
        row.peerStates = [.reported, .told, .stopped]
        row.peerTitles = ["Sidebar alignment fix", "Nightly appcast rebuild", "a933"]
        return row
    }

    @Test func theShippedRowDrawsOnePillPerAgentWithItsTitleAndState() throws {
        let provider = HomeAgentFoldRowProvider()
        let part = try #require(provider.part(Self.row()))
        guard case let .custom(custom) = part else { Issue.record("not a drawn row"); return }
        let payload = try #require(HomeAgentFoldRowProvider.payload(custom))
        let pills = HomeAgentPills(payload, shape: .pill, width: 420)
        #expect(pills.pills.map(\.title) == Self.row().peerTitles)
        #expect(pills.pills.map(\.state) == ["reported", "told", "stopped"])
        let height = provider.measure(custom, maxWidth: 420).height
        #expect(height == pills.height)
        #expect(height >= 3 * HomeAgentPills.pillHeight(.pill))

        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let h = Int(height.rounded(.up))
        let ctx = try #require(CGContext(data: nil, width: 420, height: h, bitsPerComponent: 8, bytesPerRow: 420 * 4,
                                         space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.translateBy(x: 0, y: height)
        ctx.scaleBy(x: 1, y: -1)
        provider.drawRow(custom, in: ctx, rect: CGRect(x: 0, y: 0, width: 420, height: height),
                         context: CustomRowDrawContext(outgoing: false, isDark: false, elevated: false))
        let data = try #require(ctx.makeImage()?.dataProvider?.data as Data?)
        let bytes = [UInt8](data)
        // Each pill's middle line has ink (the pill's fill), so no pill is left blank.
        for pill in pills.pills {
            let y = Int(pill.rect.midY)
            guard y < h else { Issue.record("\(pill.peer): its pill is below the row"); continue }
            let line = bytes[(y * 420 * 4)..<((y + 1) * 420 * 4)]
            #expect(line.contains { $0 > 0 }, "\(pill.peer): its pill drew nothing")
        }
    }

    /// User 2026-11-05 (msg 22013): the shipped pill is compact like the target, a 13 pt title in a 30 pt
    /// capsule whose width follows its title (a short title no longer gets a 120 pt pill).
    @Test func theShippedPillIsCompactAndHugsItsTitle() throws {
        let part = try #require(HomeAgentFoldRowProvider().part(Self.row()))
        guard case let .custom(custom) = part else { Issue.record("not a drawn row"); return }
        let payload = try #require(HomeAgentFoldRowProvider.payload(custom))
        let pills = HomeAgentPills(payload, shape: .pill, width: 900).pills
        #expect(pills.allSatisfy { $0.rect.height == 30 })
        let short = try #require(pills.first { $0.title == "a933" })
        let long = try #require(pills.first { $0.title == "Nightly appcast rebuild" })
        #expect(short.rect.width < 110)
        #expect(short.rect.width < long.rect.width)
        #expect(long.rect.width < 260)
    }

    /// A click on a pill of the shipped row names that agent (between pills, nothing), and an agent the person
    /// already opened draws no unread dot.
    @Test func theShippedRowHitTestsEachPillAndKeepsEachUnreadDot() throws {
        var row = Self.row()
        row.peerUnread = [false, false, false]
        let part = try #require(HomeAgentFoldRowProvider().part(row))
        guard case let .custom(custom) = part else { Issue.record("not a drawn row"); return }
        let payload = try #require(HomeAgentFoldRowProvider.payload(custom))
        let pills = HomeAgentPills(payload, shape: .pill, width: 420)
        #expect(pills.pills.map(\.unread) == [false, false, false])
        for pill in pills.pills {
            #expect(HomeAgentFoldRowProvider.peer(custom, at: CGPoint(x: pill.rect.midX, y: pill.rect.midY), width: 420) == pill.peer)
        }
        #expect(HomeAgentFoldRowProvider.peer(custom, at: CGPoint(x: 419, y: 1), width: 420) == nil)
        // With no unread marks (an older store) a report is unread.
        let fresh = try #require(HomeAgentFoldRowProvider().part(Self.row()))
        guard case let .custom(freshCustom) = fresh else { return }
        let freshPayload = try #require(HomeAgentFoldRowProvider.payload(freshCustom))
        #expect(HomeAgentPills(freshPayload, shape: .pill, width: 420).pills.map(\.unread) == [true, false, false])
    }

    /// In the real chat a click on a pill opens that agent (the host's agent pane), not the row's fold.
    @Test func aClickOnAPillInTheChatOpensThatAgent() throws {
        _ = NSApplication.shared
        HomeMarkdownPolicy.install()
        HomeAgentFoldRowProvider.install()
        let me = ParticipantID("user_me"), chief = ParticipantID("agent_chief")
        let people = [CmuxHomeCore.Participant(id: me, kind: .human, displayName: "Me"),
                      CmuxHomeCore.Participant(id: chief, kind: .agent, displayName: "Chief", agentClass: .chief)]
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        var fold = TranscriptItem(key: IdempotencyKey("agent-messages:0123456789abcdef"), seq: nil, author: chief,
                                  parts: [.text("▸ a959 · a931 · a933")], createdAt: base.addingTimeInterval(1), delivery: .committed)
        fold.isReadOnly = true
        fold.agentMessage = Self.row()
        let items = [
            TranscriptItem(key: IdempotencyKey("k1"), seq: Seq(1), author: chief, parts: [.text("I started three agents.")],
                           createdAt: base, delivery: .committed, messageID: MessageID("msg_1")),
            fold,
        ]
        let summary = ConversationSummary(id: ConversationID("conv_pills"), title: "Chief", participants: people, lastSeq: 1,
                                          createdAt: base, updatedAt: base, readCursors: [:], readCursorTimes: [:])
        var core = ProjectionCore(me: me)
        let (conv, w) = core.install(ConversationID("conv_pills"), items: items, summary: summary)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 480), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let controller = ChatController(host: HostView(frame: NSRect(x: 0, y: 0, width: 560, height: 480)), wake: HomeAgentMessageFoldTests.NoWake())
        window.contentView = controller.host
        let recorder = HomeAgentMessageFoldTests.Recorder()
        controller.intents = recorder
        controller.install(conv, windowStart: w.start, total: w.total)
        controller.host.layoutSubtreeIfNeeded()
        controller.demo?.layoutIfNeeded()
        controller.demo?.collection.layoutIfNeeded()
        var opened: [String] = []
        controller.onAgentPill = { opened.append($0) }

        let foldID = HomeMapping.id(fold, aliases: [:])
        let hit = try #require(pillCenter(in: controller, on: foldID, peer: "a931"), "no point is on a931's pill")
        controller.clicked(hit)
        #expect(opened == ["a931"])
        #expect(recorder.rows.isEmpty)
        withExtendedLifetime(window) {}
    }

    /// The center of `peer`'s pill in the drawn row of message `message`.
    private func pillCenter(in controller: ChatController, on message: ID, peer: String) -> CGPoint? {
        let b = controller.host.bounds
        for y in stride(from: b.minY, to: b.maxY, by: 2) {
            for x in stride(from: b.minX, to: b.maxX, by: 2) {
                let p = CGPoint(x: x, y: y)
                guard let h = controller.demo?.hit(p), h.row.ref.messageId == message, case let .custom(c) = h.row.part else { continue }
                let local = CGPoint(x: p.x - h.body.minX, y: p.y - h.body.minY)
                if HomeAgentFoldRowProvider.peer(c, at: local, width: h.body.width) == peer { return p }
            }
        }
        return nil
    }
}
