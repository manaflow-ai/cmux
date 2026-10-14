import AppKit
import CmuxHomeRender
import Foundation
import Testing
@testable import MessagesLabHome

/// The pane's clicks and Esc on bubbles (PaneHost.swift `clicked`, `escape`): a click on a text
/// bubble selects its message (Messages' highlight); a click on an attachment opens it and selects
/// nothing; Esc takes a selected bubble off; a click on empty space takes it off too.
@MainActor @Suite(.serialized) struct PaneClickTests {
    final class Wake: ChatWakeScheduler {
        func schedule(after seconds: Double, _ action: @escaping @MainActor @Sendable () -> Void) {}
        func cancel() {}
    }

    final class Intents: ChatIntents {
        var opened: [(ID, ID)] = []
        func send() -> String? { nil }
        func react(_ ref: PartRef, _ kind: Reaction.Kind) {}
        var canReact: Bool { true }
        var canReply: Bool { false }
        func pickAttachments() {}
        func takeAttachments(from pasteboard: NSPasteboard) -> Bool { false }
        func acceptsAttachments(from pasteboard: NSPasteboard) -> Bool { false }
        func draftChanged() {}
        func linkTapped(_ ref: PartRef, url: String) {}
        func canCancelSend(_ message: ID) -> Bool { false }
        func cancelSend(_ message: ID) {}
        func openAttachment(_ message: ID, _ attachment: ID) { opened.append((message, attachment)) }
        func toggleVideo(_ ref: PartRef, _ attachment: ID) {}
        func videoState(_ ref: PartRef) -> HomeVideoState { .poster }
        func scrolled() {}
        func rowsPlaced() {}
    }

    static func message(_ id: String, _ sender: String, _ parts: [Part], at t: Double) -> Message {
        Message(id: id, senderId: sender, sentAt: Instant.format(Date(timeIntervalSince1970: 1_800_000_000 + t)), parts: parts,
                replyTo: nil, status: nil, edits: nil, retractedAt: nil, reactions: [])
    }

    /// A pane with a text bubble and a file bubble from the other person, laid out off screen.
    static func pane() -> (ChatController, Intents, MessagesWindowView) {
        let file = Attachment(id: "att1", kind: "file", fileName: "notes.pdf", mimeType: "application/pdf", byteSize: 1200,
                              asset: nil, poster: nil, width: nil, height: nil, durationSeconds: nil, transfer: .done)
        let conv = Conversation(id: "conv", title: "Chief", participants: [
            Participant(id: "me", displayName: "Me", isMe: true, avatar: nil),
            Participant(id: "chief", displayName: "Chief", isMe: false, avatar: nil),
        ], messages: [
            message("m1", "chief", [.text("A plain message", runs: [])], at: 0),
            message("m2", "chief", [.attachment(file)], at: 60),
        ])
        let controller = ChatController(wake: Wake())
        let intents = Intents()
        controller.intents = intents
        controller.host.frame = NSRect(x: 0, y: 0, width: 628, height: 900)
        controller.install(conv, windowStart: 0, total: 2)
        controller.host.layoutSubtreeIfNeeded()
        let demo = controller.demo!
        demo.layoutIfNeeded()
        demo.collection.layoutIfNeeded()
        return (controller, intents, demo)
    }

    /// The center of the visible part row whose part matches.
    static func center(_ demo: MessagesWindowView, _ match: (Part) -> Bool) -> (key: String, point: CGPoint)? {
        for case let cell as RowCell in demo.collection.visibleCells {
            guard let spec = cell.spec, case let .part(row) = spec.kind, match(row.part) else { continue }
            let body = cell.convert(RowDraw.bodyRect(spec), to: demo)
            return (spec.key, CGPoint(x: body.midX, y: body.midY))
        }
        return nil
    }

    @Test func aTextBubbleClickSelectsItAndEscTakesItOff() throws {
        let (controller, _, demo) = Self.pane()
        let text = try #require(Self.center(demo) { if case .text = $0 { return true }; return false })
        controller.clicked(text.point)
        #expect(controller.selection.selectedKey == text.key)
        #expect(controller.selection.showsHighlight)
        controller.escape()
        #expect(controller.selection.selectedKey == nil)
    }

    @Test func anAttachmentClickOpensItAndSelectsNothing() throws {
        let (controller, intents, demo) = Self.pane()
        let text = try #require(Self.center(demo) { if case .text = $0 { return true }; return false })
        let file = try #require(Self.center(demo) { if case .attachment = $0 { return true }; return false })
        controller.clicked(text.point)
        #expect(controller.selection.selectedKey == text.key)
        controller.clicked(file.point)
        #expect(intents.opened.map(\.1) == ["att1"])
        #expect(controller.selection.selectedKey == nil)
    }

    @Test func theThreadLayerDrawsOverTheHeader() {
        let (controller, _, _) = Self.pane()
        #expect(controller.host.threadLayerLifted)
    }

    // MARK: Keys after a click on a bubble (routeTranscriptKey)

    /// The pane in an (unshown) window, with the transcript focused by a click on its text bubble.
    static func focusedPane() throws -> (ChatController, NSWindow, NSView) {
        _ = NSApplication.shared
        let (controller, _, demo) = pane()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 628, height: 900), styleMask: [.titled], backing: .buffered, defer: true)
        window.contentView = controller.host
        controller.host.layoutSubtreeIfNeeded()
        let text = try #require(center(demo) { if case .text = $0 { return true }; return false })
        controller.clicked(text.point)
        let doc = controller.host.scrollView.document
        #expect(window.firstResponder === doc)
        return (controller, window, doc)
    }

    static func key(_ window: NSWindow, _ chars: String, code: UInt16, mods: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: mods, timestamp: 0, windowNumber: window.windowNumber,
                         context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!
    }

    @Test(arguments: [("a", UInt16(0), NSEvent.ModifierFlags()), ("\r", 36, []), ("v", 9, [.command]), ("\u{7f}", 51, [])])
    func aKeyAfterABubbleClickGoesToTheField(_ chars: String, _ code: UInt16, _ mods: NSEvent.ModifierFlags) throws {
        let (controller, window, _) = try Self.focusedPane()
        let e = Self.key(window, chars, code: code, mods: mods)
        // The same event goes on (AppKit dispatches it to the new first responder, the field).
        #expect(controller.routeTranscriptKey(e) === e)
        #expect(window.firstResponder === controller.demo?.compose.textView.view)
    }

    @Test(arguments: [("c", UInt16(8), NSEvent.ModifierFlags.command), ("\u{F701}", 125, [.function, .numericPad]), ("\t", 48, [])])
    func copyArrowsAndTabStayWithTheTranscript(_ chars: String, _ code: UInt16, _ mods: NSEvent.ModifierFlags) throws {
        let (controller, window, doc) = try Self.focusedPane()
        let e = Self.key(window, chars, code: code, mods: mods)
        #expect(controller.routeTranscriptKey(e) === e)
        #expect(window.firstResponder === doc)
    }

    // MARK: Esc with a working Chief

    /// In the field a working Chief stops first and the selection stays (one Esc, cmux); on the
    /// transcript Esc clears the selection first (Host.swift) and gives the field its caret.
    @Test func escStopsAWorkingChiefFromTheFieldAndClearsTheSelectionFromTheTranscript() throws {
        let (controller, window, _) = try Self.focusedPane()
        var stops = 0
        controller.onStop = { stops += 1 }
        controller.isWorking = true
        let selected = controller.selection.selectedKey
        #expect(selected != nil)
        // The field's Esc (its own path, ChatController.escape): stop, selection kept.
        controller.escape()
        #expect(stops == 1)
        #expect(controller.selection.selectedKey == selected)
        // The transcript's Esc: the selection goes, the Chief keeps working, the field takes the focus.
        #expect(controller.routeTranscriptKey(Self.key(window, "\u{1b}", code: 53)) == nil)
        #expect(stops == 1)
        #expect(controller.selection.selectedKey == nil)
        #expect(window.firstResponder === controller.demo?.compose.textView.view)
        // Again from the field: stop.
        controller.escape()
        #expect(stops == 2)
    }
}
