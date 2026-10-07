import AppKit
import Foundation
import Testing
@testable import CmuxConversationCore
@testable import CmuxConversationMacUI

/// Keyboard commands, focus navigation and bubble text selection, driven by
/// real NSEvents through a conversation window that is never put on screen.
@MainActor
@Suite(.serialized) struct MacKeyboardSelectionTests {
    // MARK: Commands

    @Test func commandTableMatchesMessagesShortcuts() throws {
        func action(_ spec: String) -> Selector? {
            let (code, characters, flags) = Self.key(spec)
            let event = try? #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                                                      characters: characters, charactersIgnoringModifiers: characters.lowercased(), isARepeat: false, keyCode: code))
            return event.flatMap { MacConversationCommands.command(matching: $0)?.action }
        }
        #expect(action("cmd+r") == #selector(MacConversationViewController.replyToMessage(_:)))
        #expect(action("cmd+shift+r") == #selector(MacConversationViewController.continueLastReply(_:)))
        #expect(action("cmd+t") == #selector(MacConversationViewController.tapbackMessage(_:)))
        #expect(action("cmd+e") == #selector(MacConversationViewController.editLastMessage(_:)))
        #expect(action("cmd+return") == #selector(MacConversationViewController.sendMessage(_:)))
        #expect(action("cmd+f") == #selector(MacConversationSplitController.searchConversations(_:)))
        #expect(action("ctrl+tab") == #selector(MacConversationSplitController.selectNextConversation(_:)))
        #expect(action("ctrl+shift+tab") == #selector(MacConversationSplitController.selectPreviousConversation(_:)))
        #expect(action("cmd+c") == nil)
        #expect(action("cmd+option+r") == nil)
    }

    @Test func hostShortcutMonitorsLeaveMessagesShortcutsToTheConversationWindow() async throws {
        let lab = try await Lab()
        let other = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.titled], backing: .buffered, defer: true)
        func event(_ spec: String, in window: NSWindow) -> NSEvent {
            let (code, characters, flags) = Self.key(spec)
            return NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                    characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
        }
        #expect(MacConversationLab.handlesShortcut(event("cmd+t", in: lab.window), in: lab.window))
        #expect(MacConversationLab.handlesShortcut(event("ctrl+tab", in: lab.window), in: lab.window))
        #expect(!MacConversationLab.handlesShortcut(event("cmd+c", in: lab.window), in: lab.window))
        #expect(!MacConversationLab.handlesShortcut(event("cmd+t", in: other), in: other))
    }

    @Test func replyTargetsLatestIncomingThenTheSelectedMessage() async throws {
        let lab = try await Lab()
        lab.focusComposer()
        #expect(lab.key("cmd+r") == "keyEquivalent")
        #expect(lab.controller.replyTarget?.id == "m6")
        #expect(lab.controller.composer.isReplyMode)
        lab.key("esc")
        #expect(lab.controller.replyTarget == nil)
        #expect(!lab.controller.composer.isReplyMode)

        // Select an older incoming message from the transcript, then ⌘R.
        lab.key("shift+tab")
        #expect(lab.firstResponder === lab.controller.tableView)
        lab.key("up")
        lab.key("up")
        #expect(lab.selectedText == "see you at the standup tomorrow")
        lab.key("cmd+r")
        #expect(lab.controller.replyTarget?.id == "m4")
        #expect(lab.firstResponder === lab.controller.composer.textView)
    }

    @Test func editLastMessageAndEscapeCancelsWithoutCompletion() async throws {
        let lab = try await Lab()
        lab.focusComposer()
        lab.key("cmd+e")
        #expect(lab.controller.editingMessageID == "m5")
        #expect(lab.controller.composer.text == "sounds good, I will bring the notes")
        lab.key("esc")
        #expect(lab.controller.editingMessageID == nil)
        #expect(lab.controller.composer.text.isEmpty)
        // Esc with nothing to cancel never opens NSTextView's completion list.
        lab.controller.composer.text = "hel"
        lab.key("esc")
        #expect(lab.controller.composer.text == "hel")
        #expect(lab.window.childWindows?.isEmpty ?? true)
    }

    @Test func sendMessageShortcutSubmitsTheComposer() async throws {
        let lab = try await Lab()
        lab.focusComposer()
        lab.controller.composer.text = "via command return"
        lab.key("cmd+return")
        try await waitUntil { lab.backend.sentTexts == ["via command return"] }
        #expect(lab.controller.composer.text.isEmpty)
    }

    @Test func undoAfterSendTakesTheMessageBackAndDeleteNeedsASelection() async throws {
        let lab = try await Lab()
        lab.focusComposer()
        lab.controller.composer.text = "oops, wrong chat"
        lab.key("return")
        try await waitUntil { lab.controller.store.messages.last?.seq != nil && lab.controller.store.messages.last?.text == "oops, wrong chat" }
        let undoManager = try #require(lab.controller.composer.textView.undoManager)
        #expect(undoManager.canUndo)
        #expect(undoManager.undoMenuItemTitle == "Undo Send")
        undoManager.undo()
        try await waitUntil { !lab.backend.unsent.isEmpty }
        #expect(lab.controller.store.messages.contains { $0.isUnsent })

        // Edit > Delete and the Delete key act only on a selected message.
        #expect(!lab.controller.canPerform(#selector(NSText.delete(_:))))
        lab.key("shift+tab")
        #expect(lab.controller.canPerform(#selector(NSText.delete(_:))))
    }

    @Test func tapbackShortcutPicksWithADigitAndRestoresFocus() async throws {
        let lab = try await Lab()
        lab.focusComposer()
        lab.key("cmd+t")
        let focus = try #require(lab.controller.replyFocus)
        #expect(lab.firstResponder === focus)
        lab.key("3")
        try await waitUntil { !lab.backend.reactions.isEmpty }
        #expect(lab.backend.reactions.first?.messageID == "m6")
        #expect(lab.backend.reactions.first?.reaction == .thumbsdown)
        #expect(lab.firstResponder === lab.controller.composer.textView)

        lab.key("cmd+t")
        lab.key("esc")
        #expect(lab.firstResponder === lab.controller.composer.textView)
        #expect(lab.backend.reactions.count == 1)
    }

    // MARK: Focus navigation

    @Test func tabCyclesSearchListTranscriptAndComposer() async throws {
        let lab = try await Lab()
        lab.focusComposer()
        lab.key("tab")
        #expect(lab.isEditing(lab.split.sidebar.searchField))
        lab.key("tab")
        #expect(lab.firstResponder === lab.split.sidebar.tableView)
        lab.key("tab")
        #expect(lab.firstResponder === lab.controller.tableView)
        // Tabbing into the transcript selects the newest message.
        #expect(lab.selectedText == "great, thanks!")
        lab.key("tab")
        #expect(lab.firstResponder === lab.controller.composer.textView)
        try await waitUntil { lab.controller.keyboard.selectedRowID == nil }
        lab.key("shift+tab")
        #expect(lab.firstResponder === lab.controller.tableView)
        lab.key("shift+tab")
        #expect(lab.firstResponder === lab.split.sidebar.tableView)
    }

    @Test func arrowsMoveTheSelectedMessageAndCopyCopiesItWhole() async throws {
        let lab = try await Lab()
        lab.focusComposer()
        lab.key("shift+tab")
        lab.key("up")
        #expect(lab.selectedText == "sounds good, I will bring the notes")
        lab.key("down")
        lab.key("down")
        #expect(lab.selectedText == "great, thanks!")
        let pasteboard = NSPasteboard(name: .init("cmux.conversation.test.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        lab.controller.copyMessage(to: pasteboard)
        #expect(pasteboard.string(forType: .string) == "great, thanks!")
        // ⌘C from the transcript resolves to the conversation's Copy.
        let target = MacConversationCommands.target(for: #selector(NSText.copy(_:)), in: lab.window)
        #expect(target === lab.controller)
        lab.key("esc")
        #expect(lab.controller.keyboard.selectedRowID == nil)
        #expect(lab.firstResponder === lab.controller.composer.textView)
    }

    @Test func controlTabSwitchesConversationsAndListArrowsKeepListFocus() async throws {
        let lab = try await Lab()
        lab.focusComposer()
        let first = try #require(lab.split.selected?.id)
        lab.key("ctrl+tab")
        #expect(lab.split.selected?.id != first)
        lab.key("ctrl+shift+tab")
        #expect(lab.split.selected?.id == first)

        lab.key("tab")
        lab.key("tab")
        #expect(lab.firstResponder === lab.split.sidebar.tableView)
        lab.key(lab.split.sidebar.tableView.selectedRow == 0 ? "down" : "up")
        #expect(lab.split.selected?.id != first)
        #expect(lab.firstResponder === lab.split.sidebar.tableView)
    }

    @Test func findFocusesTheSidebarSearch() async throws {
        let lab = try await Lab()
        lab.focusComposer()
        lab.key("cmd+f")
        #expect(lab.isEditing(lab.split.sidebar.searchField))
    }

    // MARK: Bubble text selection

    @Test func dragSelectsTextInsideOneBubbleAndCopiesIt() async throws {
        let lab = try await Lab()
        lab.focusComposer()
        let text = try #require(lab.bubbleText(containing: "standup"))
        let start = try lab.point(of: "see", in: text, edge: .leading)
        let end = try lab.point(of: "standup", in: text, edge: .trailing)
        lab.drag(from: start, to: end)
        #expect(lab.firstResponder === text)
        #expect((text.string as NSString).substring(with: text.selectedRange()) == "see you at the standup")
        // Selecting text also selects its message (⌘R / ⌘T act on it).
        #expect(lab.controller.keyboard.selectedRowID == "s:m4")
        let pasteboard = NSPasteboard(name: .init("cmux.conversation.test.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        // What Edit > Copy writes for the bubble's selection.
        #expect(text.writeSelection(to: pasteboard, types: text.writablePasteboardTypes))
        #expect(pasteboard.string(forType: .string) == "see you at the standup")
        // The transcript did not scroll while the bubble tracked the drag.
        #expect(lab.controller.scrollView.contentView.bounds.origin.y == lab.scrollOrigin)
    }

    @Test func doubleClickSelectsAWordAndTheMenuAddsTextServices() async throws {
        let lab = try await Lab()
        lab.focusComposer()
        let text = try #require(lab.bubbleText(containing: "standup"))
        let word = try lab.point(of: "standup", in: text, edge: .middle)
        lab.click(word, count: 2)
        #expect((text.string as NSString).substring(with: text.selectedRange()) == "standup")

        let menu = try #require(lab.menu(at: word))
        let actions = menu.items.compactMap(\.action)
        // The message actions stay first.
        #expect(menu.items.first?.title == "Reply")
        // System text services join for the selection; editing items never do.
        #expect(menu.items.contains { $0.identifier?.rawValue == "_rvMenuItemAction" })
        #expect(!actions.contains(#selector(NSText.cut(_:))))
        #expect(!actions.contains(#selector(NSText.paste(_:))))
        #expect(!menu.items.contains { $0.submenu?.items.contains { $0.action == #selector(NSFontManager.addFontTrait(_:)) } == true })
        lab.endMenu(menu)
    }

    @Test func bubbleSelectionClearsWhenFocusLeavesAndTabReturnsToComposer() async throws {
        let lab = try await Lab()
        lab.focusComposer()
        let text = try #require(lab.bubbleText(containing: "standup"))
        lab.click(try lab.point(of: "standup", in: text, edge: .middle), count: 2)
        #expect(text.selectedRange().length > 0)
        lab.key("tab")
        #expect(lab.firstResponder === lab.controller.composer.textView)
        #expect(text.selectedRange().length == 0)
        try await waitUntil { lab.controller.keyboard.selectedRowID == nil }
    }
}

// MARK: Harness

/// A conversation window (never ordered on screen) over in-memory backends.
@MainActor
final class Lab {
    let backend = MemoryBackend(id: "direct", kind: .direct)
    let window: MacConversationWindow
    let split: MacConversationSplitController
    private(set) var scrollOrigin: CGFloat = 0
    var controller: MacConversationViewController { split.selected!.controller }

    init() async throws {
        _ = NSApplication.shared
        let entries = [
            MacConversationEntry(id: "direct", store: ConversationStore(backend: backend)),
            MacConversationEntry(id: "group", store: ConversationStore(backend: MemoryBackend(id: "group", kind: .group))),
        ]
        split = MacConversationSplitController(entries: entries)
        window = MacConversationWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 760),
                                       styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentViewController = split
        window.setContentSize(NSSize(width: 1100, height: 760))
        try await waitUntil { entries.allSatisfy { $0.store.hasLoadedNewest } && self.controller.rowView(at: self.controller.rows.count - 1) != nil }
        split.view.layoutSubtreeIfNeeded()
        scrollOrigin = controller.scrollView.contentView.bounds.origin.y
    }

    var firstResponder: NSResponder? { window.firstResponder }

    func focusComposer() { window.makeFirstResponder(controller.composer.textView) }

    func isEditing(_ field: NSTextField) -> Bool {
        (window.firstResponder as? NSText)?.delegate === field
    }

    var selectedText: String? {
        guard let id = controller.keyboard.selectedRowID else { return nil }
        return controller.rows.compactMap { row -> String? in
            if case let .message(model) = row, model.rowID == id { return model.message.text } else { return nil }
        }.first
    }

    @discardableResult
    func key(_ spec: String) -> String { MacConversationLab.sendKey(spec, to: window) }

    func bubbleText(containing query: String) -> MacBubbleTextView? {
        for index in controller.rows.indices.reversed() {
            if let model = controller.messageModel(at: index), model.message.text.contains(query), let row = controller.rowView(at: index) {
                return row.textLabel
            }
        }
        return nil
    }

    enum Edge { case leading, middle, trailing }

    /// Top-left window-content point over `word` in `text` (the lab's input coordinates).
    func point(of word: String, in text: MacBubbleTextView, edge: Edge) throws -> CGPoint {
        let range = (text.string as NSString).range(of: word)
        let manager = try #require(text.layoutManager), container = try #require(text.textContainer)
        let glyphs = manager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        let rect = manager.boundingRect(forGlyphRange: glyphs, in: container)
        let x: CGFloat
        switch edge {
        case .leading: x = rect.minX + 1
        case .middle: x = rect.midX
        case .trailing: x = rect.maxX - 1
        }
        let content = try #require(window.contentView)
        let inWindow = text.convert(CGPoint(x: x, y: rect.midY), to: nil)
        return CGPoint(x: inWindow.x, y: content.bounds.height - inWindow.y)
    }

    func drag(from: CGPoint, to: CGPoint) {
        let path = (0...12).map { step -> CGPoint in
            let t = CGFloat(step) / 12
            return CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t)
        }
        MacConversationLab.mouse(.leftMouseDown, path: path, clickCount: 1, in: window)
    }

    func click(_ point: CGPoint, count: Int) {
        for n in 1...count { MacConversationLab.mouse(.leftMouseDown, path: [point], clickCount: n, in: window) }
    }

    func menu(at point: CGPoint) -> NSMenu? {
        let location = MacConversationLab.windowPoint(point, in: window)
        guard let event = NSEvent.mouseEvent(with: .rightMouseDown, location: location, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                             context: nil, eventNumber: 0, clickCount: 1, pressure: 1),
              let frame = window.contentView?.superview, let hit = frame.hitTest(location) else { return nil }
        var view: NSView? = hit
        while let current = view {
            if let menu = current.menu(for: event) { return menu }
            view = current.superview
        }
        return nil
    }

    func endMenu(_ menu: NSMenu) { menu.delegate?.menuDidClose?(menu) }
}

final class MemoryBackend: ConversationBackend, @unchecked Sendable {
    let info: ConversationInfo
    private let lock = NSLock()
    private var _sentTexts: [String] = []
    private var _reactions: [(messageID: String, reaction: ConversationReaction?)] = []
    private var messages: [ConversationMessage]

    init(id: String, kind: ConversationKind) {
        info = ConversationInfo(id: id, title: id == "direct" ? "Lawrence Chen" : "cmux", kind: kind, participants: [
            ConversationParticipant(id: "me", name: "Me", initials: "ME", colorHex: "#0A84FF", isMe: true),
            ConversationParticipant(id: "lc", name: "Lawrence Chen", initials: "LC", colorHex: "#30B0C7", isMe: false),
        ])
        let texts = [
            ("lc", "morning! did the nightly go out?"),
            ("me", "yes, about an hour ago"),
            ("lc", "nice, I will try it after lunch"),
            ("lc", "see you at the standup tomorrow"),
            ("me", "sounds good, I will bring the notes"),
            ("lc", "great, thanks!"),
        ]
        let now = Date()
        messages = texts.enumerated().map { index, entry in
            ConversationMessage(id: "m\(index + 1)", seq: index + 1, clientMessageID: nil, senderID: entry.0,
                                sentAt: now.addingTimeInterval(TimeInterval(index - texts.count) * 30), text: entry.1)
        }
    }

    var sentTexts: [String] { lock.withLock { _sentTexts } }
    var reactions: [(messageID: String, reaction: ConversationReaction?)] { lock.withLock { _reactions } }

    func events() -> AsyncStream<ConversationBackendEvent> {
        let info = info
        return AsyncStream { continuation in
            continuation.yield(.connected(info: info, meID: "me", lagged: false))
        }
    }

    func history(beforeSeq: Int?, limit: Int) async throws -> ConversationHistoryPage {
        let page = lock.withLock { messages.filter { beforeSeq == nil || ($0.seq ?? 0) < beforeSeq! } }
        return ConversationHistoryPage(messages: Array(page.suffix(limit)), hasMore: false)
    }

    func send(_ draft: ConversationOutgoingDraft) async throws -> ConversationMessage {
        lock.withLock {
            _sentTexts.append(draft.text)
            let message = ConversationMessage(id: "m\(messages.count + 1)", seq: messages.count + 1, clientMessageID: draft.clientMessageID,
                                              senderID: "me", sentAt: Date(), text: draft.text, delivery: .sent)
            messages.append(message)
            return message
        }
    }

    func react(messageID: String, reaction: ConversationReaction?) async throws -> ConversationMessage {
        try lock.withLock {
            _reactions.append((messageID, reaction))
            guard let index = messages.firstIndex(where: { $0.id == messageID }) else { throw ConversationBackendError(code: -1, message: "no message") }
            messages[index].reactions = reaction.map { [ConversationReactionMark(participantID: "me", reaction: $0)] } ?? []
            return messages[index]
        }
    }

    func edit(messageID: String, text: String) async throws -> ConversationMessage {
        try lock.withLock {
            guard let index = messages.firstIndex(where: { $0.id == messageID }) else { throw ConversationBackendError(code: -1, message: "no message") }
            messages[index].text = text
            messages[index].editedAt = Date()
            return messages[index]
        }
    }

    func unsend(messageID: String) async throws -> ConversationMessage {
        try lock.withLock {
            guard let index = messages.firstIndex(where: { $0.id == messageID }) else { throw ConversationBackendError(code: -1, message: "no message") }
            _unsent.append(messageID)
            messages[index].unsentAt = Date()
            messages[index].text = ""
            return messages[index]
        }
    }

    private var _unsent: [String] = []
    var unsent: [String] { lock.withLock { _unsent } }

    func setTyping(_ isTyping: Bool) async {}
    func markRead(upToSeq: Int) async {}
    func uploadImage(_ data: Data, mimeType: String) async throws -> ConversationAttachment {
        throw ConversationBackendError(code: -1, message: "unsupported")
    }
    func close() {}
}

@MainActor
func waitUntil(timeout: Duration = .seconds(3), _ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        if ContinuousClock.now > deadline {
            Issue.record("condition not met before timeout")
            return
        }
        try await Task.sleep(for: .milliseconds(5))
    }
}

extension MacKeyboardSelectionTests {
    static func key(_ spec: String) -> (UInt16, String, NSEvent.ModifierFlags) {
        var flags: NSEvent.ModifierFlags = []
        var key = ""
        for token in spec.split(separator: "+").map(String.init) {
            switch token {
            case "cmd": flags.insert(.command)
            case "shift": flags.insert(.shift)
            case "option": flags.insert(.option)
            case "ctrl": flags.insert(.control)
            default: key = token
            }
        }
        switch key {
        case "tab": return (48, "\t", flags)
        case "return": return (36, "\r", flags)
        default: return ([ "r": 15, "t": 17, "e": 14, "f": 3, "c": 8 ][key] ?? 0, key, flags)
        }
    }
}
