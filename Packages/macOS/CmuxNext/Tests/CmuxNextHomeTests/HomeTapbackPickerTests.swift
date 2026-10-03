import AppKit
import CmuxHomeCore
import CmuxHomeRender
import Testing
@testable import CmuxNextHome

/// The Mac tapback picker in a bubble's context menu: emoji buttons with
/// localized accessibility labels, built on `TranscriptItem.messageID`, and
/// absent when that id is missing or the owner is offline.
@MainActor
@Suite struct HomeTapbackPickerTests {
    static let me = ParticipantID("user_me")
    static let id = ConversationID("conv_tapback")

    static func messages(myLike: Bool = false) -> [Message] {
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        let chief = ParticipantID("agent_chief")
        var out: [Message] = []
        for i in 1...4 {
            let author: ParticipantID = i % 2 == 0 ? me : chief
            var reactions: [Reaction] = []
            if myLike, i == 4 { reactions.append(Reaction(author: me, partIndex: 0, kind: .tapback(.like))) }
            let createdAt = start.addingTimeInterval(TimeInterval(i) * 30)
            out.append(Message(id: MessageID("msg_\(i)"), conversation: id, seq: Seq(i), clientMessageID: IdempotencyKey("key_\(i)"),
                               author: author, parts: [.text("Message \(i)")], createdAt: createdAt, reactions: reactions))
        }
        return out
    }

    /// A window with the transcript over `items`; the caller closes it.
    static func host(_ items: [TranscriptItem]) -> (NSWindow, HomeNativeTranscriptView) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 628, height: 700), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let view = HomeNativeTranscriptView(conversation: id, me: me)
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        view.controller.update(items: items, summary: nil, typing: [], hasOlder: false)
        view.layoutSubtreeIfNeeded()
        return (window, view)
    }

    static func lastBubbleCenter(_ view: HomeNativeTranscriptView) throws -> CGPoint {
        let last = try #require(view.controller.hits(in: view.bounds).last)
        return CGPoint(x: last.bubble.midX, y: last.bubble.midY)
    }

    @Test func pickerShowsEmojiButtonsWithLocalizedLabelsAndSendsAddReaction() throws {
        let items = CmuxHomeCore.TranscriptWindow(messages: Self.messages(myLike: true)).items(pending: [], me: Self.me)
        let (window, view) = Self.host(items)
        defer { window.close() }
        var emitted: [HomeIntent] = []
        view.controller.onIntent = { emitted.append($0) }
        let menu = try #require(view.rowHost.menu(at: try Self.lastBubbleCenter(view)))
        let picker = try #require(menu.items.first?.view as? HomeTapbackPickerView)
        #expect(menu.items.last?.action == #selector(HomeRowHostView.copyMessage(_:)))
        #expect(picker.accessibilityLabel() == HomeReactionStyle.pickerLabel)
        let glyphs: [String] = HomeReactionStyle.tapbacks.map { HomeReactionStyle.glyph($0) }
        let names: [String] = HomeReactionStyle.tapbacks.map { HomeReactionStyle.accessibilityName($0) }
        let titles: [String] = picker.buttons.map(\.title)
        let labels: [String] = picker.buttons.map { $0.accessibilityLabel() ?? "" }
        #expect(titles == glyphs)
        #expect(labels == names)
        let selected: [Bool] = picker.buttons.map { $0.isAccessibilitySelected() }
        let expected: [Bool] = HomeReactionStyle.tapbacks.map { $0 == .like }
        #expect(selected == expected, "my existing tapback shows selected")

        let laugh = try #require(picker.buttons.first { $0.accessibilityLabel() == HomeReactionStyle.accessibilityName(.laugh) })
        laugh.performClick(nil)
        let laughOp = HomeOp.addReaction(message: MessageID("msg_4"), conversation: Self.id, reaction: .tapback(.laugh), partIndex: 0)
        #expect(emitted.map(\.op) == [laughOp])
        let like = try #require(picker.buttons.first { $0.accessibilityLabel() == HomeReactionStyle.accessibilityName(.like) })
        like.performClick(nil)
        #expect(emitted.count == 1, "a tapback I already gave sends nothing")
        #expect(like.isAccessibilitySelected(), "the owner's echo, not the click, decides the selection")
    }

    @Test func noPickerWithoutAMessageIDOrWhileOffline() throws {
        var items = CmuxHomeCore.TranscriptWindow(messages: Self.messages()).items(pending: [], me: Self.me)
        let (window, view) = Self.host(items)
        defer { window.close() }
        view.isSendEnabled = false
        let offline = try #require(view.rowHost.menu(at: try Self.lastBubbleCenter(view)))
        #expect(!offline.items.contains { $0.view is HomeTapbackPickerView }, "nothing queues offline")
        view.isSendEnabled = true

        for i in items.indices { items[i].messageID = nil }
        view.controller.update(items: items, summary: nil, typing: [], hasOlder: false)
        view.layoutSubtreeIfNeeded()
        let noID = try #require(view.rowHost.menu(at: try Self.lastBubbleCenter(view)))
        #expect(noID.items.count == 1, "no fake ids: Copy only")
        #expect(noID.items.first?.action == #selector(HomeRowHostView.copyMessage(_:)))
    }

    @Test func messageElementsCarryOneAccessibilityActionPerTapback() throws {
        let items = CmuxHomeCore.TranscriptWindow(messages: Self.messages()).items(pending: [], me: Self.me)
        let (window, view) = Self.host(items)
        defer { window.close() }
        var emitted: [HomeIntent] = []
        view.controller.onIntent = { emitted.append($0) }
        let children: [Any] = view.rowHost.accessibilityChildren() ?? []
        let elements: [NSAccessibilityElement] = children.compactMap { $0 as? NSAccessibilityElement }
        let message = try #require(elements.last { $0.accessibilityLabel() == "Message 4" })
        let actions: [NSAccessibilityCustomAction] = message.accessibilityCustomActions() ?? []
        let actionNames: [String] = actions.map(\.name)
        let names: [String] = HomeReactionStyle.tapbacks.map { HomeReactionStyle.accessibilityName($0) }
        #expect(actionNames == names)
        let love = try #require(actions.first)
        #expect(love.handler?() == true)
        let loveOp = HomeOp.addReaction(message: MessageID("msg_4"), conversation: Self.id, reaction: .tapback(.love), partIndex: 0)
        #expect(emitted.map(\.op) == [loveOp])
    }
}

@MainActor
@Suite struct HomeTextScaleTests {
    /// The Mac's text size reaches the render core's `textScale` and the
    /// field: bigger text, taller field, bigger bubbles.
    @Test func textScaleGrowsTheTranscriptAndTheField() throws {
        let items = CmuxHomeCore.TranscriptWindow(messages: HomeTapbackPickerTests.messages()).items(pending: [], me: HomeTapbackPickerTests.me)
        let (window, view) = HomeTapbackPickerTests.host(items)
        defer { window.close() }
        view.applyTextScale(1)
        view.layoutSubtreeIfNeeded()
        let fieldHeight = view.field.preferredHeight
        let bubble = try #require(view.controller.hits(in: view.bounds).last).bubble
        view.applyTextScale(16.0 / 12.0)
        view.layoutSubtreeIfNeeded()
        #expect(abs(view.controller.textScale - 16.0 / 12.0) < 0.001)
        #expect(view.field.scale == view.controller.textScale)
        #expect(view.field.preferredHeight > fieldHeight)
        #expect(view.field.textView.font?.pointSize == 13 * view.controller.textScale)
        let scaled = try #require(view.controller.hits(in: view.bounds).last).bubble
        #expect(scaled.height > bubble.height)
    }
}
