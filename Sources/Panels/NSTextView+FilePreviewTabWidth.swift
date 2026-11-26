import AppKit

extension NSTextView {
    /// Applies the File Preview tab-stop width to existing paragraphs and the
    /// typing attributes used for newly inserted tabs.
    func applyFilePreviewTabWidth(_ tabWidth: Int) {
        let columns = max(1, tabWidth)
        let font = font ?? NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let spaceWidth = (" " as NSString).size(withAttributes: [.font: font]).width
        guard spaceWidth.isFinite, spaceWidth > 0 else { return }
        let interval = spaceWidth * CGFloat(columns)
        if let savingTextView = self as? SavingTextView,
           savingTextView.appliedFilePreviewTabWidth == columns,
           let previousInterval = savingTextView.appliedFilePreviewTabStopInterval,
           abs(previousInterval - interval) < 0.01 {
            return
        }

        let paragraphStyle = NSMutableParagraphStyle()
        if let defaultParagraphStyle {
            paragraphStyle.setParagraphStyle(defaultParagraphStyle)
        }
        paragraphStyle.defaultTabInterval = interval
        // Explicit stops override `defaultTabInterval`; clear them so the
        // editor and indent-guide overlay share one tab geometry.
        paragraphStyle.tabStops = []
        defaultParagraphStyle = paragraphStyle
        typingAttributes[.paragraphStyle] = paragraphStyle

        if let storage = textStorage, storage.length > 0 {
            storage.addAttribute(
                .paragraphStyle,
                value: paragraphStyle,
                range: NSRange(location: 0, length: storage.length)
            )
        }
        if let savingTextView = self as? SavingTextView {
            savingTextView.appliedFilePreviewTabWidth = columns
            savingTextView.appliedFilePreviewTabStopInterval = interval
        }
    }
}
