import AppKit
import CmuxFoundation
import CmuxSyntaxHighlighting

/// Applies Highlightr token colors onto a TextKit 1 `NSTextStorage` in place.
///
/// Does not replace the storage or assign `textView.string`. Save/dirty stay
/// on the plain string. Highlighter background is stripped so Ghostty panel
/// colors show through.
@MainActor
final class FilePreviewSyntaxStyler {
    private let catalog = LanguageCatalog()
    private let policy = HighlightPolicy()
    private let engine = HighlightrSyntaxEngine()
    private var highlightTask: Task<Void, Never>?
    private var highlightGeneration = 0
    private var lastHighlightedText: String?
    private var lastHighlightedLanguage: String?
    private var lastHighlightedTheme: TokenTheme?
    private var lastHighlightingEnabled = true

    deinit {
        highlightTask?.cancel()
    }

    func cancel() {
        highlightTask?.cancel()
    }

    func schedule(
        for textView: NSTextView,
        filePath: String,
        enabled: Bool,
        defaultColor: NSColor,
        theme: TokenTheme,
        force: Bool
    ) {
        let text = textView.string
        let language = catalog.language(for: URL(fileURLWithPath: filePath))
        if !force,
           lastHighlightedText == text,
           lastHighlightedLanguage == language,
           lastHighlightedTheme == theme,
           lastHighlightingEnabled == enabled {
            return
        }

        highlightTask?.cancel()
        highlightGeneration &+= 1
        let generation = highlightGeneration

        guard enabled, policy.shouldHighlight(content: text, language: language) else {
            applyDefaultStyle(to: textView, color: defaultColor)
            lastHighlightedText = text
            lastHighlightedLanguage = language
            lastHighlightedTheme = theme
            lastHighlightingEnabled = enabled
            return
        }

        // A later `schedule` cancels this task (generation + Task.cancel).
        // Do not debounce with Task.sleep: typing must not wait on a timer.
        highlightTask = Task { [weak self, weak textView] in
            guard !Task.isCancelled, let self else { return }
            let highlighted = await self.engine.highlight(
                text: text,
                language: language,
                theme: theme
            )
            guard !Task.isCancelled,
                  self.highlightGeneration == generation,
                  let textView,
                  textView.string == text else { return }
            self.applyHighlightedText(
                highlighted,
                to: textView,
                defaultColor: defaultColor
            )
            self.lastHighlightedText = text
            self.lastHighlightedLanguage = language
            self.lastHighlightedTheme = theme
            self.lastHighlightingEnabled = enabled
        }
    }

    func applyHighlightedText(
        _ highlighted: HighlightedText?,
        to textView: NSTextView,
        defaultColor: NSColor
    ) {
        guard let storage = textView.textStorage else { return }
        let selectedRanges = textView.selectedRanges
        let font = textView.font
            ?? GlobalFontMagnification.monospacedSystemFont(ofSize: 13, weight: .regular)
        storage.beginEditing()
        if let highlighted, highlighted.value.string == storage.string {
            let full = NSRange(location: 0, length: highlighted.value.length)
            highlighted.value.enumerateAttributes(in: full, options: []) { attributes, range, _ in
                storage.setAttributes(
                    Self.normalized(attributes, font: font),
                    range: range
                )
            }
        } else {
            let full = NSRange(location: 0, length: storage.length)
            storage.addAttribute(.foregroundColor, value: defaultColor, range: full)
            storage.addAttribute(.font, value: font, range: full)
            storage.removeAttribute(.backgroundColor, range: full)
        }
        storage.endEditing()
        restoreSelection(selectedRanges, in: textView)
    }

    private func applyDefaultStyle(to textView: NSTextView, color: NSColor) {
        applyHighlightedText(nil, to: textView, defaultColor: color)
    }

    private func restoreSelection(_ selectedRanges: [NSValue], in textView: NSTextView) {
        let contentLength = (textView.string as NSString).length
        let clamped = selectedRanges.map { value -> NSValue in
            let range = value.rangeValue
            let location = min(range.location, contentLength)
            let length = min(range.length, max(0, contentLength - location))
            return NSValue(range: NSRange(location: location, length: length))
        }
        textView.setSelectedRanges(clamped, affinity: .downstream, stillSelecting: false)
    }

    private static func normalized(
        _ attributes: [NSAttributedString.Key: Any],
        font: NSFont
    ) -> [NSAttributedString.Key: Any] {
        var normalized = attributes
        normalized.removeValue(forKey: .backgroundColor)
        if let highlightedFont = attributes[.font] as? NSFont {
            let traits = highlightedFont.fontDescriptor.symbolicTraits
            let weight: NSFont.Weight = traits.contains(.bold) ? .bold : .regular
            let base = GlobalFontMagnification.monospacedSystemFont(
                ofSize: font.pointSize,
                weight: weight
            )
            if traits.contains(.italic) {
                normalized[.font] = NSFontManager.shared.convert(base, toHaveTrait: .italicFontMask)
            } else {
                normalized[.font] = base
            }
        } else {
            normalized[.font] = font
        }
        return normalized
    }
}
