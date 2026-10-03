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
    /// the display scale (2x), so nothing is upscaled.
    @Test func everyBitmapLayerIsDrawnAtDisplayScale() async throws {
        let (window, view) = host(messages: 30)
        defer { window.close() }
        await view.controller.bitmapsSettled()
        view.layoutSubtreeIfNeeded()
        var checked = 0
        var findings: [String] = []
        func walk(_ layer: CALayer) {
            if let contents = layer.contents, CFGetTypeID(contents as CFTypeRef) == CGImage.typeID {
                let image = contents as! CGImage // swiftlint:disable:this force_cast
                checked += 1
                if layer.contentsScale < 2 { findings.append("\(layer.name ?? "layer") scale \(layer.contentsScale)") }
                let needed: CGFloat = layer.bounds.width * 2 * layer.contentsRect.width
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

