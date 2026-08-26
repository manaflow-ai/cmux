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
    private var lastHighlightedContentRevision: Int?
    private var lastHighlightedLanguage: String?
    private var lastHighlightedTheme: TokenTheme?
    private var lastHighlightingEnabled = true
    private var lastHighlightedDefaultColor: NSColor?
    private var lastHighlightedFontPointSize: CGFloat?

    deinit {
        highlightTask?.cancel()
    }

    func cancel() {
        highlightTask?.cancel()
    }

    /// Waits for the task scheduled most recently at the call site.
    ///
    /// This is a deterministic test seam; production callers continue without
    /// awaiting syntax work so typing never waits on highlighting.
    func waitForScheduledHighlight() async {
        let task = highlightTask
        await task?.value
    }

    func schedule(
        for textView: NSTextView,
        contentRevision: Int = 0,
        filePath: String,
        enabled: Bool,
        defaultColor: NSColor,
        theme: TokenTheme,
        force: Bool
    ) {
        let language = catalog.language(for: URL(fileURLWithPath: filePath))
        let fontPointSize = (textView.font
            ?? NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)).pointSize
        if !force,
           lastHighlightedContentRevision == contentRevision,
           lastHighlightedLanguage == language,
           lastHighlightedTheme == theme,
           lastHighlightingEnabled == enabled,
           lastHighlightedDefaultColor == defaultColor,
           lastHighlightedFontPointSize == fontPointSize {
            return
        }

        highlightTask?.cancel()
        highlightGeneration &+= 1
        let generation = highlightGeneration

        guard enabled else {
            applyDefaultStyle(to: textView, color: defaultColor)
            recordAppliedState(
                contentRevision: contentRevision,
                language: language,
                theme: theme,
                enabled: enabled,
                defaultColor: defaultColor,
                fontPointSize: fontPointSize
            )
            return
        }

        // Copy the document only for a real syntax request. Repeated SwiftUI
        // updates are rejected by the revision and rendering state above.
        let text = textView.string
        guard policy.shouldHighlight(content: text, language: language) else {
            applyDefaultStyle(to: textView, color: defaultColor)
            recordAppliedState(
                contentRevision: contentRevision,
                language: language,
                theme: theme,
                enabled: enabled,
                defaultColor: defaultColor,
                fontPointSize: fontPointSize
            )
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
                  let textView else { return }
            self.applyHighlightedText(
                highlighted,
                to: textView,
                defaultColor: defaultColor
            )
            self.recordAppliedState(
                contentRevision: contentRevision,
                language: language,
                theme: theme,
                enabled: enabled,
                defaultColor: defaultColor,
                fontPointSize: fontPointSize
            )
        }
    }

    func applyHighlightedText(
        _ highlighted: HighlightedText?,
        to textView: NSTextView,
        defaultColor: NSColor
    ) {
        guard let storage = textView.textStorage else { return }
        let selectedRanges = textView.selectedRanges
        let effectivePointSize = (textView.font
            ?? NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)).pointSize
        let fonts = SyntaxFonts(pointSize: effectivePointSize)
        storage.beginEditing()
        if let highlighted, highlighted.value.length == storage.length {
            let full = NSRange(location: 0, length: highlighted.value.length)
            highlighted.value.enumerateAttributes(in: full, options: []) { attributes, range, _ in
                storage.setAttributes(
                    Self.normalized(attributes, fonts: fonts),
                    range: range
                )
            }
        } else {
            let full = NSRange(location: 0, length: storage.length)
            storage.addAttribute(.foregroundColor, value: defaultColor, range: full)
            storage.addAttribute(.font, value: fonts.regular, range: full)
            storage.removeAttribute(.backgroundColor, range: full)
        }
        storage.endEditing()
        restoreSelection(selectedRanges, in: textView)
    }

    private func recordAppliedState(
        contentRevision: Int,
        language: String?,
        theme: TokenTheme,
        enabled: Bool,
        defaultColor: NSColor,
        fontPointSize: CGFloat
    ) {
        lastHighlightedContentRevision = contentRevision
        lastHighlightedLanguage = language
        lastHighlightedTheme = theme
        lastHighlightingEnabled = enabled
        lastHighlightedDefaultColor = defaultColor
        lastHighlightedFontPointSize = fontPointSize
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

    private struct SyntaxFonts {
        let regular: NSFont
        let bold: NSFont
        let italic: NSFont
        let boldItalic: NSFont

        init(pointSize: CGFloat) {
            regular = NSFont.monospacedSystemFont(ofSize: pointSize, weight: .regular)
            bold = NSFont.monospacedSystemFont(ofSize: pointSize, weight: .bold)
            italic = NSFontManager.shared.convert(regular, toHaveTrait: .italicFontMask)
            boldItalic = NSFontManager.shared.convert(bold, toHaveTrait: .italicFontMask)
        }

        func font(for traits: NSFontDescriptor.SymbolicTraits) -> NSFont {
            switch (traits.contains(.bold), traits.contains(.italic)) {
            case (true, true): boldItalic
            case (true, false): bold
            case (false, true): italic
            case (false, false): regular
            }
        }
    }

    private static func normalized(
        _ attributes: [NSAttributedString.Key: Any],
        fonts: SyntaxFonts
    ) -> [NSAttributedString.Key: Any] {
        var normalized = attributes
        normalized.removeValue(forKey: .backgroundColor)
        let traits = (attributes[.font] as? NSFont)?.fontDescriptor.symbolicTraits ?? []
        normalized[.font] = fonts.font(for: traits)
        return normalized
    }
}
