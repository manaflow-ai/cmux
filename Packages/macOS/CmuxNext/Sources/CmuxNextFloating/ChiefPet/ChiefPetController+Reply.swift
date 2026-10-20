import AppKit

/// The pet's reply box: a click on the pet opens it over the pet (in the bubble's place) on the
/// newest notice, or the Chief when there is none. Return sends the text, or opens a notice
/// that takes no typed reply; ⌘Return opens the target; a sent reply closes it.
extension ChiefPetController {
    func toggleReply() {
        if let replyPanel, replyPanel.isVisible { return closeReply() }
        openReply()
    }

    /// Opens the reply box over the pet (a click on the pet, or Message the Chief); an open one keeps its text and place.
    func openReply() {
        guard let panel else { return }
        if let replyPanel, replyPanel.isVisible { return replyPanel.present() }
        let reply = replyPanelOnce()
        reply.show(targets: ChiefPetReply.targets(feed))
        if let visible = panel.screen?.visibleFrame ?? ChiefPetPanel.screenUnderPointer()?.visibleFrame {
            reply.setFrame(ChiefPetBubblePanel.frame(height: ChiefPetReplyPanel.size.height, over: panel.frame, in: visible,
                                                     width: ChiefPetReplyPanel.size.width, gap: ChiefPetReplyPanel.gap), display: false)
        }
        hideBubble()
        reply.present()
    }

    func closeReply() {
        guard let replyPanel, replyPanel.isVisible, !closingReply else { return }
        closingReply = true
        defer { closingReply = false }
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
