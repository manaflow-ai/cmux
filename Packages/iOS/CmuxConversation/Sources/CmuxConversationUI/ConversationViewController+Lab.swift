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
        case "edit", "unsend", "select", "toggle", "retry", "discard":
            guard let message = labMessage(matching: argument) else { return "error no row" }
            switch verb {
            case "edit":
                guard store.canEdit(message) else { return "error not editable" }
                enterEditMode(for: message)
            case "unsend":
                guard store.canUnsend(message) else { return "error not unsendable" }
                store.unsend(messageID: message.id)
            case "select": setSelecting(true, initial: message.rowID)
            case "toggle": toggleSelection(message.rowID)
            case "retry": store.retry(rowID: message.rowID)
            default: store.discardFailed(rowID: message.rowID)
            }
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
        case "endselect":
            setSelecting(false)
            return "ok"
        case "rows":
            return rows.map { row -> String in
                switch row {
                case let .message(model):
                    return "\(model.isOutgoing ? ">" : "<")\(model.message.text.prefix(24))\(model.showsTail ? "~" : "")\(model.footer == .notDelivered ? "!" : "")"
                case let .notice(_, text): return "[\(text)]"
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
            case "mine": return message.senderID == store.meID && message.seq != nil && !message.isNotice
            case "failed": return message.delivery?.isFailed == true
            case "theirs": return message.senderID != store.meID
            case "last", "": return true
            default: return message.text.contains(query)
            }
        }
    }
}
#endif
