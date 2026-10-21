import AppKit

/// The composer's + button opens the + menu (`HomePlusMenu`): Attach Files or Images… (the
/// file picker, as before), then the recent clipboard (`HomeClipboardHistory`) when
/// `home.clipboardHistory` is on. A text row goes in at the caret; a picture row is attached
/// through the same intake as a paste.
extension HomeNativeTranscriptView {
    /// The app's `home.clipboardHistory` (read at each event point) and the start of its reads at
    /// activation. Call once at launch; until then the history reads only when the menu opens.
    public static func useClipboardHistory(enabled: @escaping () -> Bool) {
        HomeClipboardHistory.shared.isEnabled = enabled
        HomeClipboardHistory.shared.start()
    }

    func connectPlusMenu() {
        transcript.onPlusMenu = { [weak self] anchor in self?.showPlusMenu(above: anchor) }
    }

    /// The + menu above `anchor` (the + button). Without an attachment intake there is nothing to
    /// offer; with no clipboard rows (the history off or empty) the + opens the file picker at once,
    /// as before, rather than a menu of one row.
    func showPlusMenu(above anchor: NSView) {
        guard attachmentPreparer != nil else { return }
        let history = HomeClipboardHistory.shared
        let rows = max(0, Int(HomeTunables.plusMenuClipboardRows.value.rounded()))
        let clipboard = rows > 0 ? history.recent(rows) : []
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
