import AppKit
import CmuxNextWakeups

/// The pet's reply box: a click on the pet opens it over the pet (in the bubble's place) on the
/// newest notice, or the mini's chat when there is none (the Chief, or the chat Show in Mini
/// picked, whose newest reply it shows under the field). Return sends the text, or opens a notice
/// that takes no typed reply; ⌘Return opens the target; a sent reply closes it. Hovering the pet opens
/// it too (the hover dock, ``ChiefPetHoverDock``).
extension ChiefPetController {
    func toggleReply() {
        // A click on the pet the hover dock opened the box for keeps it, and gives it the keys.
        if let replyPanel, replyPanel.isVisible, !replyByHover { return closeReply() }
        openReply()
    }

    /// Opens the reply box over the pet (a click on the pet, or Message the Chief); an open one keeps its text and place.
    /// `byHover`: the pointer came onto the pet (the hover dock): the box shows without taking the keys, so
    /// the app being typed in keeps them until a click in the field.
    func openReply(byHover: Bool = false) {
        guard let panel else { return }
        hoverClose.cancel()
        if let replyPanel, replyPanel.isVisible {
            guard !byHover else { return }
            replyByHover = false
            return replyPanel.present()
        }
        replyByHover = byHover
        let reply = replyPanelOnce()
        reply.show(targets: ChiefPetReply.targets(feed, home: home.target))
        reply.show(latest: home.latest, of: home.target)
        place(reply, over: panel)
        hideBubble()
        // A child of the pet, as the notices are: a drag moves it with the pet.
        panel.addChildWindow(reply, ordered: .above)
        if byHover { reply.orderFrontRegardless() } else { reply.present() }
    }

    /// The hover dock (Leo 2026-10-20, the ChatGPT Codex mini pet): the pointer coming onto the pet
    /// opens its reply box; leaving the pet and the box closes a box it opened after
    /// `ChiefPetHoverDock.closeDelay`, unless the field has the caret or text by then.
    func hover(_ inside: Bool, onPet: Bool) {
        if inside {
            hoverClose.cancel()
            if onPet, isShown, !(panel?.pet.isDragging ?? false) { openReply(byHover: true) }
            return
        }
        guard replyByHover else { return }
        hoverClose.schedule(after: ChiefPetHoverDock.closeDelay) { @MainActor [weak self] in
            self?.closeHoverDockIfIdle()
        }
    }

    /// The hover dock's close: the box it opened goes unless the pointer came back or the box is in use.
    func closeHoverDockIfIdle() {
        guard let replyPanel, replyPanel.isVisible else { return }
        let point = pointer()
        let over = (panel.map { NSMouseInRect(point, $0.frame, false) } ?? false) || NSMouseInRect(point, replyPanel.frame, false)
        guard ChiefPetHoverDock.closesOnLeave(openedByHover: replyByHover, pointerOver: over,
                                              editing: replyPanel.isEditing, text: replyPanel.field.stringValue) else { return }
        closeReply()
    }

    /// Puts the open reply box back over the pet, on the side with room (after a drag or a screen change).
    func placeReply() {
        guard let panel, let replyPanel, replyPanel.isVisible else { return }
        place(replyPanel, over: panel)
    }

    private func place(_ reply: ChiefPetReplyPanel, over panel: ChiefPetPanel) {
        guard let visible = panel.visibleFrame() ?? ChiefPetPanel.screenUnderPointer()?.visibleFrame else { return }
        let frame = ChiefPetReplyPanel.frame(over: panel.frame, in: visible, height: reply.preferredHeight)
        if frame != reply.frame { reply.setFrame(frame, display: false) }
    }

    func closeReply() {
        hoverClose.cancel()
        replyByHover = false
        // Out of the pet's children first, shown or not: a hidden child would come back the next time
        // the pet is ordered in.
        if let replyPanel { replyPanel.parent?.removeChildWindow(replyPanel) }
        guard let replyPanel, replyPanel.isVisible, !closingReply else { return }
        closingReply = true
        defer { closingReply = false }
        replyPanel.orderOut(nil)
        render(animated: false)
        // The pet Message the Chief showed with the setting off goes with its box.
        guard transient, !isOn else { return }
        transient = false
        panel?.dismiss()
    }

    func submit(_ target: ChiefPetReplyTarget, text: String, command: Bool) {
        switch ChiefPetReply.submit(target, text: text, command: command) {
        case .nothing:
            return
        case .open(let target):
            closeReply()
            actions.open(target)
        case .send(let target, let text):
            guard !sending else { return }
            sending = true
            // task-owner: one send, answered once
            Task { [weak self] in
                guard let self else { return }
                let sent = await self.actions.send(target, text)
                self.sending = false
                // Not sent: the text stays in the box to try again or open the target.
                guard sent else { return NSSound.beep() }
                self.replyPanel?.field.stringValue = ""
                // To the chat Show in Mini picked the box stays open, for its reply and the next
                // message (a persistent session you keep typing to); the Chief's and a notice's close.
                if case .chat = target { return }
                self.closeReply()
            }
        }
    }

    func replyPanelOnce() -> ChiefPetReplyPanel {
        if let replyPanel { return replyPanel }
        let made = ChiefPetReplyPanel()
        made.onSubmit = { [weak self] target, text, command in self?.submit(target, text: text, command: command) }
        made.onClose = { [weak self] in self?.closeReply() }
        made.onResize = { [weak self] in self?.placeReply() }
        made.onHover = { [weak self] inside in self?.hover(inside, onPet: false) }
        replyPanel = made
        return made
    }
}

/// The hover dock's rule: a reply box the pointer opened closes once the pointer has left the pet
/// and the box for `closeDelay`, unless the field has the caret or holds text (typing is never lost).
/// A box a click or Message the Chief opened closes as it always did (Esc, a click elsewhere, a send).
enum ChiefPetHoverDock {
    static let closeDelay: Duration = .milliseconds(400)

    static func closesOnLeave(openedByHover: Bool, pointerOver: Bool, editing: Bool, text: String) -> Bool {
        openedByHover && !pointerOver && !editing && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
