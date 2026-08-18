import AppKit
import CmuxFoundation
import Foundation

extension SavingTextView {
    /// Applies the configured family, default size, and paragraph leading.
    ///
    /// A zoomed editor keeps its live size when the persisted default changes;
    /// an editor that still follows its default adopts the new size immediately.
    func configurePreviewTypography(fontFamily: String, defaultFontSize: CGFloat, lineHeight: CGFloat) {
        let normalizedFamily = FilePreviewFontFamilySettings.normalized(fontFamily)
        let normalizedSize = CGFloat(FilePreviewFontSizeSettings.clamp(Double(defaultFontSize)))
        let normalizedLineHeight = CGFloat(FilePreviewLineHeightSettings.clamp(Double(lineHeight)))
        let firstConfiguration = !hasConfiguredPreviewTypography
        let followsConfiguredSize = firstConfiguration
            || abs(previewFontSize - configuredPreviewFontSize) < 0.0001

        let familyChanged = normalizedFamily != previewFontFamily
        let sizeChanged = normalizedSize != configuredPreviewFontSize
        let lineHeightChanged = abs(normalizedLineHeight - previewLineHeight) > 0.0001

        configuredPreviewFontSize = normalizedSize
        previewFontFamily = normalizedFamily
        previewLineHeight = normalizedLineHeight
        if followsConfiguredSize {
            previewFontSize = normalizedSize
        }
        hasConfiguredPreviewTypography = true

        if familyChanged || sizeChanged || firstConfiguration {
            applyCurrentPreviewFont()
        }
        if lineHeightChanged {
            applyCurrentPreviewLineHeight()
        }
    }

    /// Rebuilds the current font from the configured family and live zoom size.
    func applyCurrentPreviewFont() {
        let scaledSize = GlobalFontMagnification.scaledSize(previewFontSize)
        let nextFont = FilePreviewFontFamilySettings.font(
            family: previewFontFamily,
            scaledPointSize: scaledSize
        ) ?? GlobalFontMagnification.monospacedSystemFont(ofSize: previewFontSize, weight: .regular)
        font = nextFont
        typingAttributes[.font] = nextFont
    }

    /// Applies the configured paragraph multiplier to existing and typed text.
    func applyCurrentPreviewLineHeight() {
        let multiplier = FilePreviewLineHeightSettings.clamp(Double(previewLineHeight))
        let typingStyleKey = NSAttributedString.Key.paragraphStyle
        if abs(multiplier - FilePreviewLineHeightSettings.defaultMultiplier) < 0.0001 {
            typingAttributes.removeValue(forKey: typingStyleKey)
            removePreviewLineHeightFromTextStorage()
            return
        }

        let style = NSMutableParagraphStyle()
        style.lineHeightMultiple = CGFloat(multiplier)
        style.minimumLineHeight = 0
        style.maximumLineHeight = 0
        typingAttributes[typingStyleKey] = style

        guard let textStorage, textStorage.length > 0 else { return }
        let fullRange = NSRange(location: 0, length: textStorage.length)
        var updates: [(NSRange, NSParagraphStyle)] = []
        textStorage.enumerateAttribute(.paragraphStyle, in: fullRange) { value, range, _ in
            let updatedStyle = (value as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle
                ?? NSMutableParagraphStyle()
            updatedStyle.lineHeightMultiple = CGFloat(multiplier)
            updatedStyle.minimumLineHeight = 0
            updatedStyle.maximumLineHeight = 0
            updates.append((range, updatedStyle))
        }
        textStorage.beginEditing()
        for (range, updatedStyle) in updates {
            textStorage.addAttribute(.paragraphStyle, value: updatedStyle, range: range)
        }
        textStorage.endEditing()
    }

    /// Restores natural leading when the configured multiplier returns to 1.0.
    private func removePreviewLineHeightFromTextStorage() {
        guard let textStorage, textStorage.length > 0 else { return }
        textStorage.removeAttribute(
            .paragraphStyle,
            range: NSRange(location: 0, length: textStorage.length)
        )
    }
}
