#if canImport(UIKit) && DEBUG
import CmuxConversationCore
import UIKit

/// DEBUG lab automation for the photo paths, so a headless simulator can be
/// driven without synthesized touches. Each verb calls the same entry point
/// a person's gesture reaches.
extension ConversationViewController {
    public func photoLabCommand(_ line: String) -> String {
        let parts = line.split(separator: " ").map(String.init)
        switch parts.first {
        case "drawer":
            presentPhotoDrawer()
            return "ok"
        case "pick":
            guard parts.count == 2, let item = Int(parts[1]), let drawer = photoDrawer else { return "error no drawer" }
            return drawer.labToggle(item: item) ? "ok" : "error no item"
        case "send":
            guard composer.hasContent else { return "error empty" }
            composerDidTapSend(composer)
            return "ok"
        case "viewer":
            let cells = collectionView.visibleCells.compactMap { $0 as? MessageCell }.sorted { $0.frame.maxY > $1.frame.maxY }
            guard let imageView = cells.lazy.compactMap({ $0.imageViews.last { !$0.isHidden && $0.image != nil } }).first else { return "error no photo" }
            presentPhotoViewer(from: imageView)
            return "ok"
        case "close":
            presentedViewController?.dismiss(animated: true)
            return "ok"
        default:
            return "error unknown verb"
        }
    }
}

extension ConversationPhotoGridView {
    func labToggle(item: Int) -> Bool {
        guard let grid = subviews.first(where: { $0 is UICollectionView }) as? UICollectionView,
              item < grid.numberOfItems(inSection: 0) else { return false }
        collectionView(grid, didSelectItemAt: IndexPath(item: item, section: 0))
        return true
    }
}

/// Lab verbs for scripted, input-free runs (headless simulators): each one
/// runs the same path as its gesture or menu item, past any confirmation.
extension ConversationViewController {
    public func labCommand(_ line: String) -> String {
        let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
        guard let verb = parts.first else { return "error empty" }
        let argument = parts.count > 1 ? parts[1] : ""
        switch verb {
        case "send":
            composer.text = argument
            composerDidTapSend(composer)
            return "ok"
        case "edit", "unsend", "select", "toggle", "retry", "discard", "textselect":
            guard let message = labMessage(matching: argument) else { return "error no row" }
            switch verb {
            case "edit":
                guard store.canEdit(message) else { return "error not editable" }
                enterEditMode(for: message)
            case "unsend":
                guard store.canUnsend(message) else { return "error not unsendable" }
                store.unsend(messageID: message.id)
            case "select": setSelecting(true, initial: message.rowID)
            case "textselect":
                guard let indexPath = indexPath(for: message.rowID),
                      let cell = collectionView.cellForItem(at: indexPath) as? MessageCell,
                      canSelectText(in: cell) else { return "error no text" }
                beginTextSelection(rowID: message.rowID)
            case "toggle": toggleSelection(message.rowID)
            case "retry": store.retry(rowID: message.rowID)
            default: store.discardFailed(rowID: message.rowID)
            }
            return "ok"
        case "notunsent":
            // Taps the newest "(!) Not Unsent" notice.
            guard let notice = rows.reversed().lazy.compactMap({ row -> ConversationNotice? in
                if case let .notice(notice) = row, notice.failure != nil { return notice } else { return nil }
            }).first else { return "error no failed notice" }
            presentNotUnsent(messageID: notice.messageID)
            return "ok"
        case "edittext":
            guard let overlay = editOverlay else { return "error not editing" }
            overlay.textView.text = argument
            overlay.textViewDidChange(overlay.textView)
            return "ok"
        case "editsave", "editcancel":
            guard let overlay = editOverlay else { return "error not editing" }
            if verb == "editsave" { overlay.saveFromLab() } else { overlay.onCancel?() }
            return "ok"
        case "deleteselected":
            guard isSelecting, !selectedRowIDs.isEmpty else { return "error nothing selected" }
            deleteSelection(selectedRowIDs)
            return "ok"
        case "textselection":
            guard let selection = textSelection else { return "none" }
            let menus = selection.interactions.filter { $0 is UIEditMenuInteraction }.count
            return "range \(selection.selectedRange.location),\(selection.selectedRange.length) of \((selection.text as NSString).length) first=\(selection.isFirstResponder) editMenus=\(menus) frame=\(selection.frame)"
        case "textmenu":
            guard let selection = textSelection else { return "none" }
            selection.showEditMenu()
            return "ok"
        case "endtextselect":
            endTextSelection()
            return "ok"
        case "forward":
            guard isSelecting, !selectedRowIDs.isEmpty else { return "error nothing selected" }
            forwardSelection()
            return "ok"
        case "forwardsheet":
            let compose = (presentedViewController as? UINavigationController)?.viewControllers.first as? ConversationComposeViewController
            return compose.map { "compose text=\($0.composer.text.replacingOccurrences(of: "\n", with: "|")) images=\($0.composer.attachments.count)" } ?? "none"
        case "selectstate":
            return "selecting=\(isSelecting) selected=\(selectedRowIDs.count) trailing=\(header.trailingMode) backAlpha=\(header.backGlass.alpha)"
        case "endselect":
            setSelecting(false)
            return "ok"
        case "rows":
            return rows.map { row -> String in
                switch row {
                case let .message(model):
                    return "\(model.isOutgoing ? ">" : "<")\(model.message.text.prefix(24))\(model.showsTail ? "~" : "")\(model.footer == .notDelivered ? "!" : "")"
                case let .notice(notice): return "[\(notice.text)]"
                case .timestamp: return "[ts]"
                default: return "[\(row.id)]"
                }
            }.suffix(Int(argument) ?? 8).joined(separator: " | ")
        default:
            return "error unknown \(verb)"
        }
    }

    /// "mine" is my newest stored message, "failed" my newest failed send,
    /// "last" the newest message; anything else matches text.
    private func labMessage(matching query: String) -> ConversationMessage? {
        store.messages.reversed().first { message in
            switch query {
            case "mine": return message.senderID == store.meID && message.seq != nil && !message.isUnsent
            case "failed": return message.delivery?.isFailed == true
            case "theirs": return message.senderID != store.meID
            case "last", "": return true
            default: return message.text.contains(query)
            }
        }
    }
}
#endif
