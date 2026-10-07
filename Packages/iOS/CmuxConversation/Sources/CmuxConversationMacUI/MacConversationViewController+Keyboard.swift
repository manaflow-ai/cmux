#if os(macOS)
import AppKit
import CmuxConversationCore

/// Keyboard state for one conversation: the selected message (Messages'
/// "selected message" that ⌘R, ⌘T and ⌘C act on), Show Times, and the
/// responder to restore after the keyboard tapback picker closes.
@MainActor
final class MacConversationKeyboardState {
    var selectedRowID: String?
    var showsTimes = false
    weak var responderBeforeTapback: NSResponder?
}

/// Whether a focus change comes from the keyboard (Tab, arrows) rather
/// than a click or a programmatic switch.
@MainActor
enum MacKeyboardNavigation {
    /// Lab-synthesized keys are dispatched outside NSApp.currentEvent.
    static var syntheticKeyDepth = 0
    static var isActive: Bool { NSApp.currentEvent?.type == .keyDown || syntheticKeyDepth > 0 }
}

extension NSView {
    /// Tab / Shift-Tab through the window's key view loop. Tables swallow Tab
    /// (it would move between editable cells), so they forward it here.
    func moveKeyFocus(_ event: NSEvent) {
        if event.modifierFlags.contains(.shift) {
            window?.selectKeyView(preceding: self)
        } else {
            window?.selectKeyView(following: self)
        }
    }
}

/// The sidebar's conversation list: Tab leaves it along the key view loop.
final class MacKeyLoopTableView: NSTableView {
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 48, event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
            moveKeyFocus(event)
            return
        }
        super.keyDown(with: event)
    }
}

/// Messages' conversation commands and keyboard navigation.
extension MacConversationViewController: MacConversationCommandValidating, NSMenuItemValidation {
    func installKeyboardSupport() {
        tableView.focusRingType = .none
        composer.textView.onCancel = { [weak self] in self?.cancelOperation(nil) }
    }

    // MARK: Targets

    private func messageIndex(where predicate: (MacMessageRowModel) -> Bool) -> Int? {
        rows.indices.reversed().first { index in messageModel(at: index).map(predicate) ?? false }
    }

    private var selectedMessageIndex: Int? {
        guard let id = keyboard.selectedRowID else { return nil }
        return rows.firstIndex { $0.id == id }
    }

    /// The selected message, else the newest stored message (incoming only
    /// when `incoming`): Messages' "latest incoming or selected message".
    private func commandTarget(incoming: Bool) -> Int? {
        if let index = selectedMessageIndex, messageModel(at: index)?.message.seq != nil { return index }
        return messageIndex { $0.message.seq != nil && (!incoming || !$0.isOutgoing) }
    }

    private var lastReplyRootID: String? {
        guard let meID = store.meID else { return nil }
        return store.messages.last { $0.senderID == meID && $0.replyToID != nil }?.replyToID
    }

    private var lastEditableIndex: Int? {
        messageIndex { $0.isOutgoing && store.canEdit($0.message) }
    }

    func canPerform(_ action: Selector) -> Bool {
        switch action {
        case #selector(sendMessage(_:)): return composer.hasContent
        case #selector(replyToMessage(_:)): return commandTarget(incoming: true) != nil
        case #selector(continueLastReply(_:)): return lastReplyRootID.flatMap { store.message(id: $0) } != nil
        case #selector(tapbackMessage(_:)): return commandTarget(incoming: false) != nil
        case #selector(editLastMessage(_:)): return lastEditableIndex != nil
        case #selector(copyMessage(_:)), #selector(copy(_:)): return selectedMessageIndex != nil
        default: return true
        }
    }

    public func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard let action = menuItem.action else { return false }
        if action == #selector(toggleShowTimes(_:)) { menuItem.state = keyboard.showsTimes ? .on : .off }
        return canPerform(action)
    }

    // MARK: Commands

    /// Edit > Send Message (⌘↩): the same submit Return performs.
    @objc func sendMessage(_ sender: Any?) {
        guard composer.hasContent else { return }
        composerDidSubmit(composer)
    }

    /// Edit > Reply to Message… (⌘R).
    @objc func replyToMessage(_ sender: Any?) {
        guard let index = commandTarget(incoming: true), let model = messageModel(at: index) else { return NSSound.beep() }
        enterReply(model.message)
    }

    /// Edit > Continue Last Reply… (⇧⌘R): back into the thread you last answered.
    @objc func continueLastReply(_ sender: Any?) {
        guard let root = lastReplyRootID.flatMap({ store.message(id: $0) }) else { return NSSound.beep() }
        enterReply(root)
    }

    /// Edit > Edit Last Message… (⌘E).
    @objc func editLastMessage(_ sender: Any?) {
        guard let index = lastEditableIndex, let model = messageModel(at: index) else { return NSSound.beep() }
        enterEdit(model.message)
    }

    /// Edit > Tapback Message… (⌘T), then 1–6 picks a tapback and Esc cancels.
    @objc func tapbackMessage(_ sender: Any?) {
        guard let index = commandTarget(incoming: false), let model = messageModel(at: index) else { return NSSound.beep() }
        tableView.scrollRowToVisible(index)
        view.layoutSubtreeIfNeeded()
        guard let row = rowView(at: index) else { return }
        keyboard.responderBeforeTapback = view.window?.firstResponder
        showReactionFocus(model, in: row)
        guard let focus = replyFocus else { return }
        let messageID = model.message.id
        let mine = model.message.reactions.first { $0.participantID == store.meID }?.reaction
        focus.onKeyDown = { [weak self] event in
            guard let self else { return false }
            if event.keyCode == 53 {
                self.dismissReactionFocus()
                return true
            }
            let reactions = ConversationReaction.allCases
            guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
                  let digit = event.charactersIgnoringModifiers.flatMap(Int.init), (1...reactions.count).contains(digit) else { return false }
            let reaction = reactions[digit - 1]
            self.store.react(messageID: messageID, reaction: mine == reaction ? nil : reaction)
            self.dismissReactionFocus()
            return true
        }
        view.window?.makeFirstResponder(focus)
    }

    /// Returns focus to where it was before the keyboard tapback picker.
    func restoreFocusAfterReactionFocus(_ focus: NSView?) {
        guard let window = view.window, let focus, window.firstResponder === focus else { return }
        let previous = keyboard.responderBeforeTapback
        keyboard.responderBeforeTapback = nil
        if let previous = previous as? NSView, previous.window === window, previous !== focus {
            window.makeFirstResponder(previous)
        } else {
            window.makeFirstResponder(composer.textView)
        }
    }

    /// View > Show Times: every message's time, as the swipe reveals it.
    @objc func toggleShowTimes(_ sender: Any?) {
        keyboard.showsTimes.toggle()
        setTimestampReveal(keyboard.showsTimes ? 1 : 0, animated: true)
    }

    /// Copies the selected message (Edit > Copy with no text selected).
    @objc func copyMessage(_ sender: Any?) {
        copyMessage(to: .general)
    }

    func copyMessage(to pasteboard: NSPasteboard) {
        guard let index = selectedMessageIndex, let model = messageModel(at: index) else { return NSSound.beep() }
        pasteboard.clearContents()
        pasteboard.setString(model.message.text, forType: .string)
    }

    @objc func copy(_ sender: Any?) { copyMessage(sender) }

    // MARK: Message selection

    /// Clicking a bubble selects its message; clicking elsewhere clears it.
    func updateMessageSelection(forClick event: NSEvent, in table: NSTableView) {
        let point = table.convert(event.locationInWindow, from: nil)
        let index = table.row(at: point)
        guard index >= 0, let model = messageModel(at: index), let row = rowView(at: index),
              row.contentFrame.contains(row.convert(point, from: table)) else {
            selectMessage(rowID: nil)
            return
        }
        selectMessage(rowID: model.rowID)
    }

    func selectMessage(rowID: String?) {
        let old = keyboard.selectedRowID
        guard old != rowID else { return }
        keyboard.selectedRowID = rowID
        for id in [old, rowID].compactMap({ $0 }) {
            guard let index = rows.firstIndex(where: { $0.id == id }), let row = rowView(at: index) else { continue }
            applyMessageSelection(to: row)
        }
    }

    /// Messages darkens a selected bubble as it does under its menu.
    func applyMessageSelection(to row: MacMessageRowView) {
        guard let model = row.model else { return }
        let selected = model.rowID == keyboard.selectedRowID
        let base: Float = model.footer == .notDelivered ? 0.85 : 1
        row.bubble.opacity = selected ? 0.72 : base
        row.emojiLabel.alphaValue = selected ? 0.72 : 1
    }

    /// Up / Down in the transcript move the selection between messages.
    func moveMessageSelection(by delta: Int) {
        let messages = rows.indices.filter { messageModel(at: $0) != nil }
        guard !messages.isEmpty else { return }
        let next: Int
        if let current = selectedMessageIndex, let position = messages.firstIndex(of: current) {
            next = messages[min(max(0, position + delta), messages.count - 1)]
        } else {
            next = messages[messages.count - 1]
        }
        if view.window?.firstResponder !== tableView { view.window?.makeFirstResponder(tableView) }
        selectMessage(rowID: rows[next].id)
        tableView.scrollRowToVisible(next)
    }

    /// Tabbing into the transcript selects the newest message, as Messages does.
    func transcriptDidBecomeFocused() {
        guard keyboard.selectedRowID == nil, MacKeyboardNavigation.isActive else { return }
        moveMessageSelection(by: 0)
    }

    /// The selection shows only while focus stays in the transcript.
    func transcriptFocusMayHaveLeft() {
        Task { @MainActor [weak self] in
            guard let self, let window = self.view.window else { return }
            if let responder = window.firstResponder as? NSView, responder.isDescendant(of: self.view) { return }
            self.selectMessage(rowID: nil)
        }
    }

    /// A text selection in a bubble also selects that bubble's message.
    func bubbleTextDidSelect(_ textView: MacBubbleTextView) {
        var view: NSView? = textView
        while let current = view, !(current is MacMessageRowView) { view = current.superview }
        guard let row = view as? MacMessageRowView, let id = row.model?.rowID, id != keyboard.selectedRowID else { return }
        selectMessage(rowID: id)
    }

    /// Esc in the transcript drops the selection and returns to the composer.
    func cancelMessageSelection() -> Bool {
        guard keyboard.selectedRowID != nil, let window = view.window,
              let responder = window.firstResponder as? NSView, responder.isDescendant(of: view) else { return false }
        selectMessage(rowID: nil)
        window.makeFirstResponder(composer.textView)
        return true
    }
}
#endif
