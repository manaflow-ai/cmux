import AppKit

/// The pet's reply box: a click on the pet opens it over the pet (in the bubble's place) on the
/// newest notice, or the Chief when there is none. Return sends the text, or opens a notice
/// that takes no typed reply; ⌘Return opens the target; a sent reply closes it.
extension ChiefPetController {
    func toggleReply() {
        if let replyPanel, replyPanel.isVisible { return closeReply() }
        guard let panel else { return }
        let reply = replyPanelOnce()
        reply.show(targets: ChiefPetReply.targets(feed))
        place(reply, over: panel)
        hideBubble()
        // A child of the pet, as the notices are: a drag moves it with the pet.
        panel.addChildWindow(reply, ordered: .above)
        reply.present()
    }

    /// Puts the open reply box back over the pet, on the side with room (after a drag or a screen change).
    func placeReply() {
        guard let panel, let replyPanel, replyPanel.isVisible else { return }
        place(replyPanel, over: panel)
    }

    private func place(_ reply: ChiefPetReplyPanel, over panel: ChiefPetPanel) {
        guard let visible = panel.visibleFrame() ?? ChiefPetPanel.screenUnderPointer()?.visibleFrame else { return }
        reply.setFrame(ChiefPetBubblePanel.frame(height: ChiefPetReplyPanel.size.height, over: panel.frame, in: visible,
                                                 width: ChiefPetReplyPanel.size.width, gap: ChiefPetReplyPanel.gap), display: false)
    }

    func closeReply() {
        guard let replyPanel, replyPanel.isVisible, !closingReply else { return }
        closingReply = true
        defer { closingReply = false }
        // Out of the pet's children first: a hidden child would come back the next time the pet is ordered in.
        replyPanel.parent?.removeChildWindow(replyPanel)
        replyPanel.orderOut(nil)
        render(animated: false)
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
                self.closeReply()
            }
        }
    }

    private func replyPanelOnce() -> ChiefPetReplyPanel {
        if let replyPanel { return replyPanel }
        let made = ChiefPetReplyPanel()
        made.onSubmit = { [weak self] target, text, command in self?.submit(target, text: text, command: command) }
        made.onClose = { [weak self] in self?.closeReply() }
        replyPanel = made
        return made
    }
}
