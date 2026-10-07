#if os(macOS)
import AppKit
import CmuxConversationCore

/// VoiceOver for the macOS transcript, phrased like Messages (shared with
/// iOS through `ConversationAccessibilityText`): each bubble row is one
/// element ("Ana, On my way, You loved this, 9:41 PM") whose value carries
/// what sits below it ("Edited", "Delivered"), with Tapback, Reply, Copy,
/// Edit and Try Again as VoiceOver actions on the same paths as the menu.
extension MacConversationViewController {
    func configureAccessibility(_ row: MacMessageRowView, model: MacMessageRowModel) {
        let message = model.message
        let meID = store.meID
        row.setAccessibilityLabel(ConversationAccessibilityText.messageLabel(
            message,
            isOutgoing: model.isOutgoing,
            senderName: model.senderName,
            reactorName: { [weak self] id in id == meID ? nil : self?.store.info?.participant(id)?.name }
        ))
        var value: [String] = []
        if message.editedAt != nil {
            value.append(String(localized: "conversation.message.edited", defaultValue: "Edited", bundle: .module))
        }
        switch model.footer {
        case .none: break
        case let .status(text): value.append(text)
        case .notDelivered: value.append(ConversationAccessibilityText.sendFailure)
        }
        row.setAccessibilityValue(value.isEmpty ? nil : value.joined(separator: ", "))
        row.setAccessibilityHelp(message.seq != nil ? ConversationAccessibilityText.reactHintMac : nil)

        var actions: [NSAccessibilityCustomAction] = []
        if message.seq != nil {
            actions.append(NSAccessibilityCustomAction(name: ConversationAccessibilityText.tapbackAction) { [weak self, weak row] in
                guard let self, let row else { return false }
                self.showReactionFocus(model, in: row)
                return true
            })
            actions.append(NSAccessibilityCustomAction(name: ConversationAccessibilityText.replyAction) { [weak self] in
                self?.enterReply(message)
                return true
            })
        }
        if !message.text.isEmpty {
            actions.append(NSAccessibilityCustomAction(name: ConversationAccessibilityText.copyAction) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(message.text, forType: .string)
                Self.announce(ConversationAccessibilityText.copiedAnnouncement)
                return true
            })
        }
        if store.canEdit(message) {
            actions.append(NSAccessibilityCustomAction(name: ConversationAccessibilityText.editAction) { [weak self] in
                self?.enterEdit(message)
                return true
            })
        }
        if message.delivery?.isFailed == true {
            let rowID = model.rowID
            actions.append(NSAccessibilityCustomAction(name: ConversationAccessibilityText.tryAgainAction) { [weak self] in
                self?.store.retry(rowID: rowID)
                return true
            })
        }
        row.setAccessibilityCustomActions(actions)
    }

    /// Messages speaks a message that arrives in the open conversation.
    func announceArrivals(_ inserted: [MacConversationRow], change: ConversationStoreChange) {
        guard case .live = change else { return }
        let arrivals = inserted.compactMap { row -> MacMessageRowModel? in
            if case let .message(model) = row, !model.isOutgoing { return model }
            return nil
        }
        guard let last = arrivals.last else { return }
        Self.announce(ConversationAccessibilityText.receivedAnnouncement(senderName: last.senderName, text: last.message.text))
    }

    static func announce(_ text: String) {
        guard let element = NSApp.mainWindow ?? NSApp.keyWindow else { return }
        NSAccessibility.post(element: element, notification: .announcementRequested, userInfo: [
            .announcement: text,
            .priority: NSAccessibilityPriorityLevel.high.rawValue,
        ])
    }
}
#endif
