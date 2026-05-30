import AppKit

extension NSTextView {
    func configureCmuxNaturalWritingDirectionForComposedText() {
        baseWritingDirection = .natural
        alignment = .natural

        let paragraphStyle = cmuxNaturalComposedTextParagraphStyle()
        defaultParagraphStyle = paragraphStyle

        var attributes = typingAttributes
        attributes[.paragraphStyle] = paragraphStyle
        typingAttributes = attributes
    }

    func applyCmuxNaturalWritingDirectionToComposedText() {
        configureCmuxNaturalWritingDirectionForComposedText()

        let fullRange = NSRange(location: 0, length: (string as NSString).length)
        guard fullRange.length > 0 else { return }

        textStorage?.setAlignment(.natural, range: fullRange)
        textStorage?.setBaseWritingDirection(.natural, range: fullRange)
    }

    func cmuxNaturalComposedTextParagraphStyle() -> NSParagraphStyle {
        let paragraphStyle = (defaultParagraphStyle?.mutableCopy() as? NSMutableParagraphStyle)
            ?? NSMutableParagraphStyle()
        paragraphStyle.alignment = .natural
        paragraphStyle.baseWritingDirection = .natural
        return paragraphStyle.copy() as! NSParagraphStyle
    }
}
