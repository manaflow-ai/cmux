import AppKit
import CmuxHomeCore
import CmuxHomeRender
import Testing
@testable import CmuxNextHome

/// Selftest and audit of the native AppKit transcript host (run on the GUI
/// build host): the scroll bridge in both directions, sending from the
/// field, accessibility, and the resolution of every rendered layer.
@MainActor
@Suite struct HomeNativeTranscriptTests {
    static let me = ParticipantID("user_me")
    static let chief = ParticipantID("agent_chief")
    static let conversation = ConversationID("conv_native")
    static let start = Date(timeIntervalSince1970: 1_790_000_000)

    private static let longText = "A longer message that wraps across more than one line in the bubble."

    private static func message(_ i: Int) -> Message {
        let author: ParticipantID = i % 3 == 0 ? me : chief
        let text: String = i % 5 == 0 ? longText : "Line \(i)"
        let seconds: TimeInterval = TimeInterval(i) * 30
        let id = MessageID("msg_\(i)")
        let key = IdempotencyKey("key_\(i)")
        let parts: [MessagePart] = [.text(text)]
        return Message(id: id, conversation: conversation, seq: Seq(i), clientMessageID: key, author: author,
                       parts: parts, createdAt: start.addingTimeInterval(seconds))
    }

    private func items(_ count: Int) -> [TranscriptItem] {
        var messages: [Message] = []
        for i in 1...count { messages.append(Self.message(i)) }
        let window = CmuxHomeCore.TranscriptWindow(messages: messages)
        return window.items(pending: [], me: Self.me)
    }

    private func summary() -> ConversationSummary {
        ConversationSummary(id: Self.conversation,
                            participants: [Participant(id: Self.me, kind: .human, displayName: "Me"),
                                           Participant(id: Self.chief, kind: .agent, displayName: "Chief", agentClass: .chief)],
                            createdAt: Self.start, updatedAt: Self.start, readCursors: [:])
    }

    private func host(messages: Int = 60) -> (NSWindow, HomeNativeTranscriptView) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 628, height: 900), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let view = HomeNativeTranscriptView(conversation: Self.conversation, me: Self.me)
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        view.controller.update(items: items(messages), summary: summary(), typing: [], hasOlder: false)
        view.layoutSubtreeIfNeeded()
        return (window, view)
    }

    @Test func theCoreRangeDrivesTheDocumentAndTheClip() {
        let (window, view) = host()
        defer { window.close() }
        let g = view.controller.scrollGeometry
        #expect(g.offset == g.pinnedOffset, "a fresh transcript shows its newest row")
        let doc: CGRect = view.scroll.document.frame
        let clipHeight: CGFloat = view.scroll.clip.bounds.height
        let expectedHeight: CGFloat = g.pinnedOffset - g.minOffset + clipHeight
        let topError: CGFloat = abs(doc.minY - g.minOffset)
        let heightError: CGFloat = abs(doc.height - expectedHeight)
        let clipError: CGFloat = abs(view.scroll.clip.bounds.origin.y - g.offset)
        #expect(topError < 0.01)
        #expect(heightError < 0.01)
        #expect(clipError < 0.01)
        #expect(view.scroll.rowHost.frame.origin == view.scroll.clip.bounds.origin, "rows stay on the visible area")
    }

    @Test func aUserScrollReachesTheCore() {
        let (window, view) = host()
        defer { window.close() }
        let g = view.controller.scrollGeometry
        let target: CGFloat = g.offset - 400
        view.scroll.clip.scroll(to: NSPoint(x: 0, y: target))
        let offsetError: CGFloat = abs(view.controller.scrollGeometry.offset - target)
        #expect(offsetError < 0.01)
        #expect(!view.controller.isPinnedToNewest)
        #expect(view.scroll.rowHost.frame.origin == view.scroll.clip.bounds.origin)
    }

    private func key(_ window: NSWindow, _ chars: String, code: UInt16, flags: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: window.windowNumber,
                         context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!
    }

    @Test func returnSendsAndShiftReturnAddsALine() throws {
        let (window, view) = host(messages: 8)
        defer { window.close() }
        var sent: [HomeIntent] = []
        view.controller.onIntent = { sent.append($0) }
        view.field.text = "Status?"
        view.field.textView.keyDown(with: key(window, "\r", code: 36, flags: .shift))
        #expect(sent.isEmpty)
        #expect(view.field.text.contains("\n"))
        view.field.text = "Ship it"
        let shortHeight = view.field.preferredHeight
        view.field.textView.keyDown(with: key(window, "\r", code: 36))
        let intent = try #require(sent.first)
        guard case .sendMessage(let conversation, let parts) = intent.op else { Issue.record("not a send"); return }
        #expect(conversation == Self.conversation)
        #expect(parts == [.text("Ship it")])
        #expect(view.field.text.isEmpty)
        #expect(view.field.preferredHeight == shortHeight)
    }

    @Test func everyVisibleMessageIsAnAccessibilityElement() throws {
        let (window, view) = host(messages: 12)
        defer { window.close() }
        let children = try #require(view.rowHost.accessibilityChildren() as? [NSAccessibilityElement])
        let items = view.controller.accessibilityItems()
        #expect(!items.isEmpty)
        #expect(children.count == items.count)
        #expect(view.rowHost.accessibilityRole() == .list)
        for (e, item) in zip(children, items) {
            #expect(e.accessibilityLabel() == item.label)
            #expect(!(e.accessibilityLabel() ?? "").isEmpty)
        }
    }

    /// Resolution audit: every layer that shows a bitmap draws it at least at
    /// the window's backing scale (2x on Retina), so nothing is upscaled.
    @Test func everyBitmapLayerIsDrawnAtDisplayScale() async throws {
        let (window, view) = host(messages: 30)
        defer { window.close() }
        await view.controller.bitmapsSettled()
        view.layoutSubtreeIfNeeded()
        let expected: CGFloat = window.backingScaleFactor
        var checked = 0
        var findings: [String] = []
        func walk(_ layer: CALayer) {
            if let contents = layer.contents, CFGetTypeID(contents as CFTypeRef) == CGImage.typeID {
                let image = contents as! CGImage // swiftlint:disable:this force_cast
                checked += 1
                if layer.contentsScale < expected { findings.append("\(layer.name ?? "layer") scale \(layer.contentsScale)") }
                let needed: CGFloat = layer.bounds.width * expected * layer.contentsRect.width
                let pixels: CGFloat = CGFloat(image.width) + 1
                let unit = CGRect(x: 0, y: 0, width: 1, height: 1)
                if layer.contentsCenter == unit, pixels < needed {
                    findings.append("\(layer.name ?? "layer") \(image.width) px for \(layer.bounds.width) pt")
                }
            }
            layer.sublayers?.forEach(walk)
        }
        walk(view.controller.rootLayer)
        #expect(checked > 0, "rows rendered bitmaps")
        #expect(findings.isEmpty, "\(findings)")
    }
}

@MainActor
@Suite struct HomeFieldSpringTests {
    /// The field view's keyframes are the render core's: they start at the
    /// old frame and end at the new one.
    @Test func keyframesComeFromTheCore() throws {
        let view = NSView(frame: CGRect(x: 0, y: 0, width: 300, height: 79))
        let new = CGRect(x: 0, y: 49, width: 300, height: 30)
        let frames: [CGRect] = [CGRect(x: 0, y: 0, width: 300, height: 79), CGRect(x: 0, y: 30, width: 300, height: 49), new]
        HomeFieldSpring.animate(view, to: new, keyframes: (0.5, [0, 0.5, 1], frames))
        let size = try #require(view.animations["frameSize"] as? CAKeyframeAnimation)
        let values = try #require(size.values as? [NSValue])
        #expect(values.first?.sizeValue.height == 79)
        #expect(values.last?.sizeValue.height == 30)
        #expect(size.duration == 0.5)
    }
}

@MainActor
@Suite struct HomeGlassHeaderTests {
    @Test func headerShowsTheOtherParticipantAndRowsScrollUnderIt() {
        let me = ParticipantID("user_me")
        let chief = ParticipantID("agent_chief")
        let id = ConversationID("conv_header")
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        let participants: [Participant] = [Participant(id: me, kind: .human, displayName: "Me"),
                                           Participant(id: chief, kind: .agent, displayName: "Chief Of Staff", agentClass: .chief)]
        let summary = ConversationSummary(id: id, participants: participants, createdAt: start, updatedAt: start, readCursors: [:])
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 628, height: 900), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let view = HomeNativeTranscriptView(conversation: id, me: me)
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        view.controller.update(items: [], summary: summary, typing: [], hasOlder: false)
        view.layoutSubtreeIfNeeded()
        #expect(view.header.name.title == "Chief Of Staff")
        #expect(view.header.avatar.stringValue == "CO")
        let headerHeight: CGFloat = HomeGlassHeaderView.height
        #expect(view.header.frame.height == headerHeight)
        #expect(view.controller.topInset == headerHeight)
    }
}

/// The local conversation owner refuses create, invite, pin and mute
/// (`unsupported_on_local_owner`) until the cloud owner lands, so the native
/// transcript offers none of them: no menu, no header action, and the only
/// ops it can emit are sends and read cursors.
@MainActor
@Suite struct HomeLocalOwnerActionTests {
    @Test func noUnsupportedActionsOnALocalConversation() {
        let me = ParticipantID("user_me")
        let id = ConversationID("conv_local")
        let view = HomeNativeTranscriptView(conversation: id, me: me)
        #expect(view.menu == nil)
        #expect(view.header.menu == nil)
        #expect(view.header.name.action == nil, "the name pill opens nothing")
        var ops: [HomeOp] = []
        view.controller.onIntent = { ops.append($0.op) }
        view.controller.sendHosted(text: "hi", from: .zero)
        for op in ops {
            switch op {
            case .sendMessage, .setReadCursor: break
            default: Issue.record("unsupported op on a local conversation: \(op)")
            }
        }
        #expect(!ops.isEmpty)
    }
}

@MainActor
@Suite struct HomeOfflineSendTests {
    /// H17: offline, Return keeps the text as a draft and emits nothing.
    @Test func offlineReturnKeepsTheDraft() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 628, height: 600), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let view = HomeNativeTranscriptView(conversation: ConversationID("conv_off"), me: ParticipantID("user_me"))
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        var sent = 0
        view.controller.onIntent = { _ in sent += 1 }
        view.isSendEnabled = false
        view.field.text = "later"
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                     windowNumber: window.windowNumber, context: nil, characters: "\r",
                                     charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)
        if let event { view.field.textView.keyDown(with: event) }
        #expect(sent == 0)
        #expect(view.field.text == "later")
    }
}

@MainActor
@Suite struct HomeContextMenuTests {
    /// A context menu on a bubble offers Copy for that message, nothing on
    /// empty space. (The Copy action itself is not run: the user's clipboard stays.)
    @Test func bubbleMenuOffersCopyOfThatMessage() throws {
        let me = ParticipantID("user_me")
        let id = ConversationID("conv_menu")
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        var messages: [Message] = []
        for i in 1...6 {
            let author: ParticipantID = i % 2 == 0 ? me : ParticipantID("agent_chief")
            let parts: [MessagePart] = [.text("Message \(i)")]
            let message = Message(id: MessageID("msg_\(i)"), conversation: id, seq: Seq(i), clientMessageID: IdempotencyKey("key_\(i)"),
                                  author: author, parts: parts, createdAt: start.addingTimeInterval(TimeInterval(i) * 30))
            messages.append(message)
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 628, height: 700), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let view = HomeNativeTranscriptView(conversation: id, me: me)
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        let items = CmuxHomeCore.TranscriptWindow(messages: messages).items(pending: [], me: me)
        view.controller.update(items: items, summary: nil, typing: [], hasOlder: false)
        view.layoutSubtreeIfNeeded()
        let hits = view.controller.hits(in: view.bounds)
        let last = try #require(hits.last)
        let menu = try #require(view.rowHost.menu(at: CGPoint(x: last.bubble.midX, y: last.bubble.midY)))
        #expect(menu.items.count == 1)
        #expect(menu.items.first?.action == #selector(HomeRowHostView.copyMessage(_:)))
        #expect(view.rowHost.menuHit?.text == "Message 6")
        #expect(view.rowHost.menu(at: CGPoint(x: 2, y: last.bubble.midY)) == nil)
    }
}

@MainActor
@Suite struct HomeSelectionTests {
    /// A drag from the first to the last of three messages selects all
    /// three, top to bottom, and draws one highlight. (Copy is not run: the
    /// user's clipboard stays.)
    @Test func dragAcrossRowsSelectsEveryMessageItMeets() throws {
        let me = ParticipantID("user_me")
        let id = ConversationID("conv_select")
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        var messages: [Message] = []
        for i in 1...3 {
            let parts: [MessagePart] = [.text("Part \(i)")]
            let author: ParticipantID = i == 2 ? me : ParticipantID("agent_chief")
            let message = Message(id: MessageID("msg_\(i)"), conversation: id, seq: Seq(i), clientMessageID: IdempotencyKey("key_\(i)"),
                                  author: author, parts: parts, createdAt: start.addingTimeInterval(TimeInterval(i) * 30))
            messages.append(message)
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 628, height: 700), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let view = HomeNativeTranscriptView(conversation: id, me: me)
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        let items = CmuxHomeCore.TranscriptWindow(messages: messages).items(pending: [], me: me)
        view.controller.update(items: items, summary: nil, typing: [], hasOlder: false)
        view.layoutSubtreeIfNeeded()
        let hits = view.controller.hits(in: view.bounds)
        #expect(hits.count == 3)
        let first = try #require(hits.first)
        let last = try #require(hits.last)
        view.rowHost.dragSelect(from: CGPoint(x: first.bubble.midX, y: first.bubble.midY),
                                to: CGPoint(x: last.bubble.midX, y: last.bubble.midY))
        #expect(view.rowHost.selection.map(\.text) == ["Part 1", "Part 2", "Part 3"])
        #expect(view.rowHost.selectedText == "Part 1\n\nPart 2\n\nPart 3")
        #expect(view.rowHost.selectionLayer.path != nil)
        #expect(view.rowHost.acceptsFirstResponder)
    }
}
