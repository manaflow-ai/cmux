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
        /// The pasteboards the field's Paste offered the attachment intake (taken: nothing else pastes).
        var pasted: [NSPasteboard.Name] = []
        func send() -> String? { nil }
        func react(_ ref: PartRef, _ kind: Reaction.Kind) {}
        var canReact: Bool { true }
        var canReply: Bool { false }
        func pickAttachments() {}
        func takeAttachments(from pasteboard: NSPasteboard) -> Bool { pasted.append(pasteboard.name); return true }
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

    /// Fails when a MessagesLab roll renames or removes WindowView's `threadLayer` (read by reflection,
    /// PaneHost+ThreadLayer.swift): the header would then stay sharp under an open thread view.
    @Test func theReflectedThreadLayerIsTheWindowViewsThreadLayer() throws {
        let (_, _, demo) = Self.pane()
        let reflected = try #require(HostView.reflectedThreadLayer(of: demo), "MessagesWindowView has no threadLayer property")
        #expect(reflected === HostView.threadLayerByPlace(of: demo))
        #expect(reflected.superview === demo)
    }

    // MARK: Keys after a click on a bubble (routeTranscriptKey)

    /// The pane in an (unshown) window, with the transcript focused by a click on its text bubble.
    /// The fake intents of the last `focusedPane` (the controller holds its intents weakly).
    static var lastIntents: Intents?

    static func focusedPane() throws -> (ChatController, NSWindow, NSView) {
        _ = NSApplication.shared
        let (controller, intents, demo) = pane()
        lastIntents = intents
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

    /// A key press for the routing tests (Sendable for Swift Testing's arguments).
    struct Press: Sendable, CustomStringConvertible {
        var chars: String
        var code: UInt16
        var mods: UInt = 0
        var description: String { "key \(code) mods \(mods)" }
    }

    static let toField = [Press(chars: "a", code: 0), Press(chars: "\r", code: 36),
                          Press(chars: "v", code: 9, mods: NSEvent.ModifierFlags.command.rawValue), Press(chars: "\u{7f}", code: 51)]
    static let staying = [Press(chars: "c", code: 8, mods: NSEvent.ModifierFlags.command.rawValue),
                          Press(chars: "\u{F701}", code: 125, mods: NSEvent.ModifierFlags([.function, .numericPad]).rawValue),
                          Press(chars: "\t", code: 48)]

    @Test(arguments: toField)
    func aKeyAfterABubbleClickGoesToTheField(_ press: Press) throws {
        let (controller, window, _) = try Self.focusedPane()
        let e = Self.key(window, press.chars, code: press.code, mods: NSEvent.ModifierFlags(rawValue: press.mods))
        // The same event goes on (AppKit dispatches it to the new first responder, the field).
        #expect(controller.routeTranscriptKey(e) === e)
        #expect(window.firstResponder === controller.demo?.compose.textView.view)
    }

    @Test(arguments: staying)
    func copyArrowsAndTabStayWithTheTranscript(_ press: Press) throws {
        let (controller, window, doc) = try Self.focusedPane()
        let e = Self.key(window, press.chars, code: press.code, mods: NSEvent.ModifierFlags(rawValue: press.mods))
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

    // MARK: Paste after a click on a bubble (a key equivalent, not a key down)

    /// The field's Paste reads a pasteboard of its own here (`FieldTextView.pasteboard`, which its Paste
    /// offers Home's attachment intake first; the fake intake takes it), so no test touches the shared
    /// general pasteboard (other test processes on the worker use it).
    static func privatePasteboard(_ controller: ChatController) throws -> NSPasteboard {
        let field = try #require(controller.demo?.compose.textView.view)
        let pb = NSPasteboard(name: NSPasteboard.Name("cmux-test-\(UUID().uuidString)"))
        field.pasteboard = pb
        return pb
    }

    /// Command-V through the window's key equivalent path (AppKit asks the window's views before the
    /// main menu): the field takes the focus and pastes.
    @Test func commandVAfterABubbleClickPastesIntoTheField() throws {
        let (controller, window, _) = try Self.focusedPane()
        let pb = try Self.privatePasteboard(controller)
        defer { pb.releaseGlobally() }
        #expect(window.performKeyEquivalent(with: Self.key(window, "v", code: 9, mods: .command)))
        #expect(window.firstResponder === controller.demo?.compose.textView.view)
        #expect(Self.lastIntents?.pasted == [pb.name])
    }

    /// The main menu's Paste (`paste:` to the first responder) with the transcript focused.
    @Test func theMenusPasteAfterABubbleClickPastesIntoTheField() throws {
        let (controller, window, doc) = try Self.focusedPane()
        let pb = try Self.privatePasteboard(controller)
        defer { pb.releaseGlobally() }
        #expect(doc.tryToPerform(#selector(TranscriptDocumentView.paste(_:)), with: nil))
        #expect(window.firstResponder === controller.demo?.compose.textView.view)
        #expect(Self.lastIntents?.pasted == [pb.name])
    }

    /// With the field focused, Command-V is the menu's Paste as everywhere else: the transcript does not
    /// take the key equivalent (it redirects only after a click on a bubble focused it).
    @Test func commandVWithTheFieldFocusedIsLeftToTheMenu() throws {
        let (controller, window, _) = try Self.focusedPane()
        let field = try #require(controller.demo?.compose.textView.view)
        window.makeFirstResponder(field)
        let pb = try Self.privatePasteboard(controller)
        defer { pb.releaseGlobally() }
        _ = window.performKeyEquivalent(with: Self.key(window, "v", code: 9, mods: .command))
        #expect(Self.lastIntents?.pasted.isEmpty == true)
    }

    /// Command-V with the field focused and no bubble click: the main menu's Paste. AppKit sends the
    /// menu item's nil-targeted `paste:` to the key window's first responder and up its chain; this is
    /// that dispatch on the pane's window (a test window is not key), and the field pastes.
    @Test func theMenusPasteWithTheFieldFocusedPastesIntoTheField() throws {
        let (controller, window, _) = try Self.focusedPane()
        let field = try #require(controller.demo?.compose.textView.view)
        window.makeFirstResponder(field)
        let pb = try Self.privatePasteboard(controller)
        defer { pb.releaseGlobally() }
        let item = NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        #expect(window.firstResponder?.tryToPerform(#selector(NSText.paste(_:)), with: item) == true)
        #expect(window.firstResponder === field)
        #expect(Self.lastIntents?.pasted == [pb.name])
    }

    // MARK: The header under an open thread or reply view

    /// The vendored thread layer (backdrop and rows) sits under the header, unmasked; the header takes the
    /// backdrop's blur and tint itself on the vendored animations' timing, so rows pass under the avatar
    /// and the pill, and the whole header blurs and dims with the transcript.
    @Test func underAnOpenThreadTheHeaderBlursOverTheThreadLayer() throws {
        let (controller, _, demo) = Self.pane()
        let host = controller.host
        let header = host.paneHeader
        header.title = "Chief"
        host.needsLayout = true
        host.layoutSubtreeIfNeeded()
        #expect(host.threadHost.root.mask == nil)
        let views = host.subviews
        let threadIndex = try #require(views.firstIndex(of: host.threadHost))
        #expect((views.firstIndex(of: header) ?? -1) > threadIndex)
        #expect(header.avatar.superview === header)
        #expect(header.layer?.filters == nil)
        #expect(header.threadBlurHost.superview === host)
        #expect(header.threadBlurHost.isHidden)
        controller.dispatch(.reply(PartRef(messageId: "m1", partIndex: 0)))
        host.needsLayout = true
        host.layoutSubtreeIfNeeded()
        #expect(demo.threadOpen)
        #expect(header.threadBlurOpen)
        // No filter or backdrop: a blurred, tinted image of the controls over the header, faded in on the
        // vendored tint's timing while the live controls fade out.
        #expect(header.layer?.filters == nil)
        #expect(!header.threadBlurHost.isHidden)
        #expect((views.firstIndex(of: header.threadBlurHost) ?? -1) > (views.firstIndex(of: header) ?? Int.max))
        #expect(header.threadBlurHost.layer?.mask == nil)
        #expect(header.threadBlurHost.image.contents != nil)
        // One picture at a time: the live controls hidden (rim included), the picture blurring and dimming.
        #expect(header.avatar.layer?.opacity == 0)
        #expect(header.pill.layer?.opacity == 0)
        #expect(header.pillRim.layer?.opacity == 0)
        #expect(header.threadBlurHost.image.filters?.count == 1)
        #expect(abs(header.threadBlurHost.tint.opacity - Float(1 - PaneHeaderView.headerGain)) < 0.0001)
        // The picture is padded by 3 x the blur radius beyond the controls on every side.
        let pad = PaneHeaderView.pictureMargin
        #expect(header.threadBlurHost.frame.maxY >= host.convert(header.pill.frame, from: header).maxY + pad - 0.5)
        let vendoredTint = try #require(host.vendoredBackdropRoot?.sublayers?.last?.animation(forKey: "thread") as? CABasicAnimation)
        let ours = try #require(header.threadBlurHost.tint.animation(forKey: "cmux.thread.tint") as? CABasicAnimation)
        #expect(ours.duration == vendoredTint.duration)
        let thread = try #require(HostView.threadLayerView(of: demo))
        let dim = thread.subviews.first?.layer
        let rows = (thread.layer.sublayers ?? []).filter { $0 !== dim }
        #expect(!rows.isEmpty)
        #expect(rows.allSatisfy { $0.mask == nil })
        #expect(header.pillGlass.frame == header.pill.frame)
        controller.dispatch(.closeThread)
        #expect(!header.threadBlurOpen)
    }
}
