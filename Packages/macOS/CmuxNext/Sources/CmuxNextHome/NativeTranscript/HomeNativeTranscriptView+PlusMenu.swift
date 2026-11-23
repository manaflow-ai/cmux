import AppKit
import CmuxNextHomeModel

/// The composer's + button opens the + menu (`HomePlusMenu`): Attach Files or Images… (the
/// file picker, as before), then the recent clipboard (`HomeClipboardHistory`) when
/// `home.clipboardHistory` is on. A text row goes in at the caret; a picture row is attached
/// through the same intake as a paste.
extension HomeNativeTranscriptView {
    func connectPlusMenu() {
        transcript.onPlusMenu = { [weak self] anchor in self?.showPlusMenu(above: anchor) }
    }

    /// The + menu above `anchor` (the + button). Without an attachment intake there is nothing to
    /// offer; with no clipboard rows (the history off or empty) the + opens the file picker at once,
    /// as before, rather than a menu of one row. Without a ``clipboardHistory`` (a composer the app
    /// gave none) there are no clipboard rows.
    func showPlusMenu(above anchor: NSView) {
        guard attachmentPreparer != nil else { return }
        let rows = max(0, Int(HomeTunables.plusMenuClipboardRows.value.rounded()))
        guard let history = clipboardHistory, rows > 0 else { pickFiles(); return }
        let clipboard = history.recent(rows)
        guard !clipboard.isEmpty else { pickFiles(); return }
        let model = HomePlusMenuModel.sections(clipboard: clipboard)
        let menu = HomePlusMenu.make(model, thumbnail: { history.thumbnail(for: $0) }) { [weak self] item in
            self?.choosePlusMenuItem(item)
        }
        HomePlusMenu.popUp(menu, above: anchor)
    }

    /// A chosen + menu row.
    func choosePlusMenuItem(_ item: HomePlusMenuItem) {
        switch item {
        case .attachFiles:
            pickFiles()
        case .clipboard(let entry):
            switch entry.content {
            case .text(let text):
                transcript.insertIntoPrimaryInput(text)
            case .image(let data, let type):
                attach([.data(data, typeIdentifier: type)])
                transcript.focusPrimaryInputForTyping()
            }
        }
    }
}
