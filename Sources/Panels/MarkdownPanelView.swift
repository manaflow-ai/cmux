import AppKit
import SwiftUI
import Runestone

/// SwiftUI view that renders a MarkdownPanel's content using a read-only
/// Runestone surface.
struct MarkdownPanelView: View {
    @ObservedObject var panel: MarkdownPanel
    let isFocused: Bool
    let isVisibleInUI: Bool
    let portalPriority: Int
    let onRequestPanelFocus: () -> Void

    @State private var focusFlashOpacity: Double = 0.0
    @State private var focusFlashAnimationGeneration: Int = 0
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Group {
            if panel.isFileUnavailable {
                fileUnavailableView
            } else {
                markdownContentView
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(backgroundColor)
        .overlay {
            RoundedRectangle(cornerRadius: FocusFlashPattern.ringCornerRadius)
                .stroke(cmuxAccentColor().opacity(focusFlashOpacity), lineWidth: 3)
                .shadow(color: cmuxAccentColor().opacity(focusFlashOpacity * 0.35), radius: 10)
                .padding(FocusFlashPattern.ringInset)
                .allowsHitTesting(false)
        }
        .overlay {
            if isVisibleInUI {
                MarkdownPointerObserver(onPointerDown: onRequestPanelFocus)
            }
        }
        .onChange(of: panel.focusFlashToken) {
            triggerFocusFlashAnimation()
        }
    }

    private var markdownContentView: some View {
        RunestoneMarkdownTextSurface(
            markdown: panel.content,
            ghosttyConfig: ghosttyConfig,
            isFocused: isFocused
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var fileUnavailableView: some View {
        VStack(spacing: 12) {
            Image(systemName: "doc.questionmark")
                .font(.system(size: 40))
                .foregroundColor(.secondary)
            Text(String(localized: "markdown.fileUnavailable.title", defaultValue: "File unavailable"))
                .font(.headline)
                .foregroundColor(.primary)
            Text(String(localized: "markdown.fileUnavailable.message", defaultValue: "The file may have been moved or deleted."))
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var backgroundColor: Color {
        Color(nsColor: ghosttyConfig.backgroundColor)
    }

    private var ghosttyConfig: GhosttyConfig {
        GhosttyConfig.load(preferredColorScheme: preferredColorScheme)
    }

    private var preferredColorScheme: GhosttyConfig.ColorSchemePreference {
        switch colorScheme {
        case .dark:
            return .dark
        case .light:
            return .light
        @unknown default:
            return .dark
        }
    }

    private func triggerFocusFlashAnimation() {
        focusFlashAnimationGeneration &+= 1
        let generation = focusFlashAnimationGeneration
        focusFlashOpacity = FocusFlashPattern.values.first ?? 0

        for segment in FocusFlashPattern.segments {
            DispatchQueue.main.asyncAfter(deadline: .now() + segment.delay) {
                guard focusFlashAnimationGeneration == generation else { return }
                withAnimation(focusFlashAnimation(for: segment.curve, duration: segment.duration)) {
                    focusFlashOpacity = segment.targetOpacity
                }
            }
        }
    }

    private func focusFlashAnimation(for curve: FocusFlashCurve, duration: TimeInterval) -> Animation {
        switch curve {
        case .easeIn:
            return .easeIn(duration: duration)
        case .easeOut:
            return .easeOut(duration: duration)
        }
    }
}

struct RunestoneMarkdownTextSurface: NSViewRepresentable {
    let markdown: String
    let ghosttyConfig: GhosttyConfig
    let isFocused: Bool

    func makeNSView(context: Context) -> MarkdownPanelRunestoneView {
        let view = MarkdownPanelRunestoneView()
        view.update(markdown: markdown, ghosttyConfig: ghosttyConfig, isFocused: isFocused)
        return view
    }

    func updateNSView(_ nsView: MarkdownPanelRunestoneView, context: Context) {
        nsView.update(markdown: markdown, ghosttyConfig: ghosttyConfig, isFocused: isFocused)
    }
}

final class MarkdownPanelRunestoneView: NSView, TextViewDelegate {
    let editor = TextView(frame: .zero)

    private var currentMarkdown = ""
    private var currentThemeKey = ""
    private var currentFocusState = false
    private var wantsFirstResponderWhenAttached = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false

        editor.translatesAutoresizingMaskIntoConstraints = false
        addSubview(editor)
        NSLayoutConstraint.activate([
            editor.leadingAnchor.constraint(equalTo: leadingAnchor),
            editor.trailingAnchor.constraint(equalTo: trailingAnchor),
            editor.topAnchor.constraint(equalTo: topAnchor),
            editor.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        configureEditor()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if wantsFirstResponderWhenAttached {
            focusEditorIfNeeded()
        }
    }

    func update(markdown: String, ghosttyConfig: GhosttyConfig, isFocused: Bool) {
        let theme = MarkdownPanelTheme(config: ghosttyConfig)
        let themeKey = theme.cacheKey
        let themeChanged = themeKey != currentThemeKey
        let contentChanged = markdown != currentMarkdown
        let focusChanged = isFocused != currentFocusState

        guard themeChanged || contentChanged || focusChanged else {
            return
        }

        let previousOrigin = editor.contentView.bounds.origin
        let previousViewportHeight = editor.contentView.bounds.height
        let previousDocumentHeight = editor.documentView?.frame.height ?? 0
        let previousScrollRatio = markdownScrollRatio(
            originY: previousOrigin.y,
            documentHeight: previousDocumentHeight,
            viewportHeight: previousViewportHeight
        )

        editor.theme = theme
        editor.backgroundColor = theme.editorBackgroundColor
        editor.textView.backgroundColor = theme.editorBackgroundColor
        editor.textView.textColor = theme.textColor
        editor.textView.selectedTextAttributes = [
            .backgroundColor: ghosttyConfig.selectionBackground,
            .foregroundColor: ghosttyConfig.selectionForeground
        ]
        editor.selectionBarColor = theme.textColor
        editor.selectionHighlightColor = theme.markedTextBackgroundColor
        editor.insertionPointColor = ghosttyConfig.cursorColor

        if contentChanged {
            editor.text = markdown
            currentMarkdown = markdown
        }

        MarkdownPanelAttributedRenderer.render(
            markdown: editor.text,
            in: editor.textView.textStorage,
            theme: theme
        )

        if contentChanged {
            restoreScrollPosition(
                previousRatio: previousScrollRatio,
                viewportHeight: editor.contentView.bounds.height
            )
        } else if themeChanged {
            editor.contentView.scroll(to: previousOrigin)
            editor.reflectScrolledClipView(editor.contentView)
        }

        currentThemeKey = themeKey
        currentFocusState = isFocused
        if isFocused && focusChanged {
            focusEditorIfNeeded()
        } else if !isFocused {
            wantsFirstResponderWhenAttached = false
        }
    }

    private func configureEditor() {
        editor.editorDelegate = self
        editor.isEditable = true
        editor.isSelectable = true
        editor.showLineNumbers = false
        editor.gutterLeadingPadding = 0
        editor.gutterTrailingPadding = 0
        editor.isLineWrappingEnabled = true
        editor.lineBreakMode = .byWordWrapping
        editor.showPageGuide = false
        editor.hasHorizontalScroller = false
        editor.hasVerticalScroller = true
        editor.borderType = .noBorder
        editor.textView.textContainerInset = NSSize(width: 10, height: 8)
        editor.textView.isAutomaticQuoteSubstitutionEnabled = false
        editor.textView.isAutomaticDashSubstitutionEnabled = false
        editor.textView.isAutomaticTextReplacementEnabled = false
        editor.textView.isAutomaticSpellingCorrectionEnabled = false
        editor.textView.isAutomaticTextCompletionEnabled = false
        editor.textView.isAutomaticDataDetectionEnabled = false
        editor.textView.isAutomaticLinkDetectionEnabled = false
        editor.textView.isContinuousSpellCheckingEnabled = false
        editor.textView.isGrammarCheckingEnabled = false
        editor.textView.allowsUndo = false
        editor.textView.isRichText = false
        editor.textView.usesFindPanel = true
    }

    private func markdownScrollRatio(originY: CGFloat, documentHeight: CGFloat, viewportHeight: CGFloat) -> CGFloat {
        let scrollableHeight = max(documentHeight - viewportHeight, 0)
        guard scrollableHeight > 0 else {
            return 0
        }
        return min(max(originY / scrollableHeight, 0), 1)
    }

    private func restoreScrollPosition(previousRatio: CGFloat, viewportHeight: CGFloat) {
        let documentHeight = editor.documentView?.frame.height ?? 0
        let scrollableHeight = max(documentHeight - viewportHeight, 0)
        let restoredY = scrollableHeight * previousRatio
        editor.contentView.scroll(to: NSPoint(x: 0, y: restoredY))
        editor.reflectScrolledClipView(editor.contentView)
    }

    func textView(_ textView: TextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
        false
    }

    private func focusEditorIfNeeded() {
        guard let window else {
            wantsFirstResponderWhenAttached = true
            return
        }
        wantsFirstResponderWhenAttached = false
        guard !editor.textView.isFirstResponder(in: window) else {
            return
        }
        _ = window.makeFirstResponder(editor.textView)
    }
}

final class MarkdownPanelTheme: Theme {
    let cacheKey: String
    let font: NSFont
    let textColor: NSColor
    let gutterBackgroundColor: NSColor
    let gutterHairlineColor: NSColor
    let lineNumberColor: NSColor
    let lineNumberFont: NSFont
    let selectedLineBackgroundColor: NSColor
    let selectedLinesLineNumberColor: NSColor
    let selectedLinesGutterBackgroundColor: NSColor
    let invisibleCharactersColor: NSColor
    let pageGuideHairlineColor: NSColor
    let pageGuideBackgroundColor: NSColor
    let markedTextBackgroundColor: NSColor

    let editorBackgroundColor: NSColor
    let secondaryTextColor: NSColor
    let tertiaryTextColor: NSColor
    let headingColor: NSColor
    let linkColor: NSColor
    let quoteColor: NSColor
    let codeColor: NSColor
    let codeBackgroundColor: NSColor
    let separatorColor: NSColor

    private let strongFontValue: NSFont
    private let emphasisFontValue: NSFont
    private let codeFontValue: NSFont
    private let headingFonts: [NSFont]

    init(config: GhosttyConfig) {
        let isLightBackground = config.backgroundColor.isLightColor
        let baseFont = MarkdownPanelTheme.font(
            family: config.fontFamily,
            size: config.fontSize,
            weight: .regular
        )
        cacheKey = [
            config.fontFamily,
            String(format: "%.2f", config.fontSize),
            config.backgroundColor.hexString(),
            config.foregroundColor.hexString(),
            config.cursorColor.hexString(),
            config.selectionBackground.hexString(),
            config.selectionForeground.hexString(),
            config.palette[2]?.hexString() ?? "nil",
            config.palette[4]?.hexString() ?? "nil",
            config.palette[5]?.hexString() ?? "nil"
        ].joined(separator: "|")

        font = baseFont
        lineNumberFont = MarkdownPanelTheme.font(
            family: config.fontFamily,
            size: max(config.fontSize - 1, 10),
            weight: .regular
        )
        strongFontValue = NSFontManager.shared.convert(baseFont, toHaveTrait: .boldFontMask)
        emphasisFontValue = NSFontManager.shared.convert(baseFont, toHaveTrait: .italicFontMask)
        codeFontValue = MarkdownPanelTheme.font(
            family: config.fontFamily,
            size: config.fontSize,
            weight: .regular
        )

        editorBackgroundColor = config.backgroundColor
        textColor = config.foregroundColor
        secondaryTextColor = config.foregroundColor.blended(withFraction: 0.28, of: config.backgroundColor) ?? config.foregroundColor
        tertiaryTextColor = config.foregroundColor.blended(withFraction: 0.5, of: config.backgroundColor) ?? config.foregroundColor
        headingColor = config.palette[5] ?? config.palette[13] ?? config.foregroundColor
        linkColor = config.palette[4] ?? config.palette[12] ?? config.foregroundColor
        quoteColor = secondaryTextColor
        codeColor = config.palette[2] ?? config.palette[10] ?? config.foregroundColor
        codeBackgroundColor = config.backgroundColor.blended(
            withFraction: isLightBackground ? 0.18 : 0.28,
            of: config.selectionBackground
        ) ?? config.selectionBackground
        separatorColor = tertiaryTextColor
        gutterHairlineColor = tertiaryTextColor.withAlphaComponent(isLightBackground ? 0.3 : 0.45)
        pageGuideHairlineColor = gutterHairlineColor
        pageGuideBackgroundColor = codeBackgroundColor
        markedTextBackgroundColor = config.selectionBackground.withAlphaComponent(isLightBackground ? 0.22 : 0.3)
        selectedLineBackgroundColor = config.selectionBackground.withAlphaComponent(isLightBackground ? 0.08 : 0.12)

        gutterBackgroundColor = editorBackgroundColor
        lineNumberColor = tertiaryTextColor
        selectedLinesLineNumberColor = textColor
        selectedLinesGutterBackgroundColor = editorBackgroundColor
        invisibleCharactersColor = tertiaryTextColor

        headingFonts = (1...6).map { level in
            let size = baseFont.pointSize + CGFloat(7 - level) * 2.6
            return MarkdownPanelTheme.font(
                family: config.fontFamily,
                size: size,
                weight: level <= 2 ? .bold : .semibold
            )
        }
    }

    private static func font(family: String, size: CGFloat, weight: NSFont.Weight) -> NSFont {
        if let font = NSFontManager.shared.font(
            withFamily: family,
            traits: weight >= .semibold ? .boldFontMask : [],
            weight: weight >= .bold ? 9 : (weight >= .semibold ? 7 : 5),
            size: size
        ) {
            return font
        }
        if let font = NSFont(name: family, size: size) {
            return font
        }
        return NSFont.monospacedSystemFont(ofSize: size, weight: weight)
    }

    func headingFont(for level: Int) -> NSFont {
        headingFonts[max(0, min(headingFonts.count - 1, level - 1))]
    }

    var strongFont: NSFont {
        strongFontValue
    }

    var emphasisFont: NSFont {
        emphasisFontValue
    }

    var codeFont: NSFont {
        codeFontValue
    }
}

private extension NSResponder {
    func isDescendant(of ancestor: NSResponder) -> Bool {
        var current: NSResponder? = self
        while let responder = current {
            if responder === ancestor {
                return true
            }
            current = responder.nextResponder
        }
        return false
    }
}

private extension NSTextView {
    func isFirstResponder(in window: NSWindow) -> Bool {
        guard let responder = window.firstResponder else {
            return false
        }
        return responder === self || responder.isDescendant(of: self)
    }
}

enum MarkdownPanelAttributedRenderer {
    private static let markdownLinkRegex = makeRegex(#"\[([^\]]+)\]\(([^)\s]+)\)"#)
    private static let autolinkRegex = makeRegex(#"<((?:https?|mailto):[^>\s]+)>"#)
    private static let strongRegex = makeRegex(#"(\*\*[^*\n]+\*\*|__[^_\n]+__)"#)
    private static let emphasisRegex = makeRegex(#"(?<!\*)\*[^*\n]+\*(?!\*)|(?<!_)_[^_\n]+_(?!_)"#)
    private static let inlineCodeRegex = makeRegex(#"`[^`\n]+`"#)
    private static let unorderedListRegex = makeRegex(#"^\s*(?:[-*+]\s+)"#)
    private static let orderedListRegex = makeRegex(#"^\s*\d+\.\s+"#)
    private static let taskListRegex = makeRegex(#"^\s*[-*+]\s+\[[ xX]\]\s+"#)
    private static let blockQuoteRegex = makeRegex(#"^\s*>\s?.*$"#)
    private static let thematicBreakRegex = makeRegex(#"^\s*(?:-{3,}|\*{3,}|_{3,})\s*$"#)
    private static let fenceRegex = makeRegex(#"^\s*```"#)

    static func render(markdown: String, in textStorage: NSTextStorage?, theme: MarkdownPanelTheme) {
        guard let textStorage else {
            return
        }

        let source = markdown as NSString
        let fullRange = NSRange(location: 0, length: source.length)
        let excludedInlineRanges = NSMutableArray()

        textStorage.beginEditing()
        defer { textStorage.endEditing() }

        let baseParagraphStyle = paragraphStyle(
            lineSpacing: 3,
            paragraphSpacing: 8,
            paragraphSpacingBefore: 0
        )
        textStorage.setAttributes(
            [
                .font: theme.font,
                .foregroundColor: theme.textColor,
                .paragraphStyle: baseParagraphStyle
            ],
            range: fullRange
        )

        var isInsideFencedCodeBlock = false
        var location = 0
        while location < source.length {
            let lineRange = source.lineRange(for: NSRange(location: location, length: 0))
            let lineContentRange = trimmedLineContentRange(for: lineRange, in: source)
            let lineText = source.substring(with: lineContentRange)

            if matches(Self.fenceRegex, lineText) {
                excludedInlineRanges.add(NSValue(range: lineContentRange))
                textStorage.addAttributes(
                    [
                        .font: theme.codeFont,
                        .foregroundColor: theme.tertiaryTextColor,
                        .backgroundColor: theme.codeBackgroundColor,
                        .paragraphStyle: paragraphStyle(lineSpacing: 2, paragraphSpacing: 6, paragraphSpacingBefore: 6)
                    ],
                    range: lineRange
                )
                isInsideFencedCodeBlock.toggle()
                location = NSMaxRange(lineRange)
                continue
            }

            if isInsideFencedCodeBlock {
                excludedInlineRanges.add(NSValue(range: lineContentRange))
                textStorage.addAttributes(
                    [
                        .font: theme.codeFont,
                        .foregroundColor: theme.codeColor,
                        .backgroundColor: theme.codeBackgroundColor,
                        .paragraphStyle: paragraphStyle(lineSpacing: 2, paragraphSpacing: 4, paragraphSpacingBefore: 0)
                    ],
                    range: lineRange
                )
                location = NSMaxRange(lineRange)
                continue
            }

            if let heading = headingMetadata(in: lineText) {
                let hashRange = NSRange(
                    location: lineContentRange.location + heading.hashRange.location,
                    length: heading.hashRange.length
                )
                let titleRange = NSRange(
                    location: lineContentRange.location + heading.titleRange.location,
                    length: heading.titleRange.length
                )
                textStorage.addAttributes(
                    [
                        .foregroundColor: theme.tertiaryTextColor
                    ],
                    range: hashRange
                )
                textStorage.addAttributes(
                    [
                        .font: theme.headingFont(for: heading.level),
                        .foregroundColor: theme.headingColor
                    ],
                    range: titleRange
                )
                textStorage.addAttribute(
                    .paragraphStyle,
                    value: paragraphStyle(
                        lineSpacing: 4,
                        paragraphSpacing: heading.level <= 2 ? 16 : 10,
                        paragraphSpacingBefore: heading.level == 1 ? 8 : 4
                    ),
                    range: lineRange
                )
                location = NSMaxRange(lineRange)
                continue
            }

            if matches(Self.blockQuoteRegex, lineText) {
                textStorage.addAttributes(
                    [
                        .foregroundColor: theme.quoteColor,
                        .paragraphStyle: paragraphStyle(lineSpacing: 3, paragraphSpacing: 8, paragraphSpacingBefore: 0)
                    ],
                    range: lineRange
                )
            } else if matches(Self.thematicBreakRegex, lineText) {
                textStorage.addAttributes(
                    [
                        .foregroundColor: theme.separatorColor,
                        .paragraphStyle: paragraphStyle(lineSpacing: 2, paragraphSpacing: 12, paragraphSpacingBefore: 6)
                    ],
                    range: lineRange
                )
            } else if lineText.contains("|") {
                textStorage.addAttributes(
                    [
                        .font: theme.codeFont,
                        .foregroundColor: theme.textColor
                    ],
                    range: lineContentRange
                )
            }

            if let markerRange = listMarkerRange(in: lineText) {
                let absoluteMarkerRange = NSRange(
                    location: lineContentRange.location + markerRange.location,
                    length: markerRange.length
                )
                textStorage.addAttribute(
                    .foregroundColor,
                    value: theme.tertiaryTextColor,
                    range: absoluteMarkerRange
                )
            }

            location = NSMaxRange(lineRange)
        }

        applyStrongAttributes(to: textStorage, in: fullRange, theme: theme, excludedRanges: excludedInlineRanges)
        applyEmphasisAttributes(to: textStorage, in: fullRange, theme: theme, excludedRanges: excludedInlineRanges)
        applyInlineCodeAttributes(to: textStorage, in: fullRange, theme: theme, excludedRanges: excludedInlineRanges)
        applyLinkAttributes(to: textStorage, markdown: source, in: fullRange, theme: theme, excludedRanges: excludedInlineRanges)
    }

    private static func applyStrongAttributes(
        to textStorage: NSTextStorage,
        in fullRange: NSRange,
        theme: MarkdownPanelTheme,
        excludedRanges: NSMutableArray
    ) {
        Self.strongRegex.enumerateMatches(in: textStorage.string, range: fullRange) { match, _, _ in
            guard let range = match?.range, range.length > 0 else { return }
            guard !intersectsExcludedRanges(range, excludedRanges: excludedRanges) else { return }
            textStorage.addAttribute(.font, value: theme.strongFont, range: range)
        }
    }

    private static func applyEmphasisAttributes(
        to textStorage: NSTextStorage,
        in fullRange: NSRange,
        theme: MarkdownPanelTheme,
        excludedRanges: NSMutableArray
    ) {
        Self.emphasisRegex.enumerateMatches(in: textStorage.string, range: fullRange) { match, _, _ in
            guard let range = match?.range, range.length > 0 else { return }
            guard !intersectsExcludedRanges(range, excludedRanges: excludedRanges) else { return }
            textStorage.addAttribute(.font, value: theme.emphasisFont, range: range)
        }
    }

    private static func applyInlineCodeAttributes(
        to textStorage: NSTextStorage,
        in fullRange: NSRange,
        theme: MarkdownPanelTheme,
        excludedRanges: NSMutableArray
    ) {
        Self.inlineCodeRegex.enumerateMatches(in: textStorage.string, range: fullRange) { match, _, _ in
            guard let range = match?.range, range.length > 0 else { return }
            guard !intersectsExcludedRanges(range, excludedRanges: excludedRanges) else { return }
            textStorage.addAttributes(
                [
                    .font: theme.codeFont,
                    .foregroundColor: theme.codeColor,
                    .backgroundColor: theme.codeBackgroundColor
                ],
                range: range
            )
        }
    }

    private static func applyLinkAttributes(
        to textStorage: NSTextStorage,
        markdown: NSString,
        in fullRange: NSRange,
        theme: MarkdownPanelTheme,
        excludedRanges: NSMutableArray
    ) {
        Self.markdownLinkRegex.enumerateMatches(in: markdown as String, range: fullRange) { match, _, _ in
            guard let match else { return }
            guard !intersectsExcludedRanges(match.range, excludedRanges: excludedRanges) else { return }
            let urlString = markdown.substring(with: match.range(at: 2))
            guard let url = URL(string: urlString) else { return }
            textStorage.addAttributes(
                [
                    .foregroundColor: theme.linkColor,
                    .underlineStyle: NSUnderlineStyle.single.rawValue,
                    .link: url
                ],
                range: match.range
            )
        }

        Self.autolinkRegex.enumerateMatches(in: markdown as String, range: fullRange) { match, _, _ in
            guard let match else { return }
            guard !intersectsExcludedRanges(match.range, excludedRanges: excludedRanges) else { return }
            let urlString = markdown.substring(with: match.range(at: 1))
            guard let url = URL(string: urlString) else { return }
            textStorage.addAttributes(
                [
                    .foregroundColor: theme.linkColor,
                    .underlineStyle: NSUnderlineStyle.single.rawValue,
                    .link: url
                ],
                range: match.range
            )
        }
    }

    private static func headingMetadata(in lineText: String) -> (level: Int, hashRange: NSRange, titleRange: NSRange)? {
        let source = lineText as NSString
        var level = 0
        while level < min(6, source.length), source.character(at: level) == unichar(35) {
            level += 1
        }
        guard level > 0,
              source.length > level,
              CharacterSet.whitespaces.contains(UnicodeScalar(source.character(at: level))!) else {
            return nil
        }

        let titleLocation = level + 1
        guard titleLocation <= source.length else {
            return nil
        }

        let titleLength = source.length - titleLocation
        guard titleLength > 0 else {
            return nil
        }

        return (
            level,
            NSRange(location: 0, length: level),
            NSRange(location: titleLocation, length: titleLength)
        )
    }

    private static func listMarkerRange(in lineText: String) -> NSRange? {
        let fullRange = NSRange(location: 0, length: (lineText as NSString).length)
        if let match = Self.taskListRegex.firstMatch(in: lineText, range: fullRange) {
            return match.range
        }
        if let match = Self.unorderedListRegex.firstMatch(in: lineText, range: fullRange) {
            return match.range
        }
        if let match = Self.orderedListRegex.firstMatch(in: lineText, range: fullRange) {
            return match.range
        }
        return nil
    }

    private static func paragraphStyle(
        lineSpacing: CGFloat,
        paragraphSpacing: CGFloat,
        paragraphSpacingBefore: CGFloat
    ) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = lineSpacing
        style.paragraphSpacing = paragraphSpacing
        style.paragraphSpacingBefore = paragraphSpacingBefore
        style.lineBreakMode = .byWordWrapping
        return style
    }

    private static func trimmedLineContentRange(for lineRange: NSRange, in source: NSString) -> NSRange {
        var length = lineRange.length
        while length > 0 {
            let character = source.character(at: lineRange.location + length - 1)
            if character == 10 || character == 13 {
                length -= 1
            } else {
                break
            }
        }
        return NSRange(location: lineRange.location, length: length)
    }

    private static func matches(_ regex: NSRegularExpression, _ text: String) -> Bool {
        regex.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) != nil
    }

    private static func intersectsExcludedRanges(_ range: NSRange, excludedRanges: NSMutableArray) -> Bool {
        for case let value as NSValue in excludedRanges {
            if NSIntersectionRange(range, value.rangeValue).length > 0 {
                return true
            }
        }
        return false
    }

    private static func makeRegex(_ pattern: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern)
    }
}

private struct MarkdownPointerObserver: NSViewRepresentable {
    let onPointerDown: () -> Void

    func makeNSView(context: Context) -> MarkdownPanelPointerObserverView {
        let view = MarkdownPanelPointerObserverView()
        view.onPointerDown = onPointerDown
        return view
    }

    func updateNSView(_ nsView: MarkdownPanelPointerObserverView, context: Context) {
        nsView.onPointerDown = onPointerDown
    }
}

final class MarkdownPanelPointerObserverView: NSView {
    var onPointerDown: (() -> Void)?
    private var eventMonitor: Any?
    private weak var forwardedMouseTarget: NSView?

    override var mouseDownCanMoveWindow: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        installEventMonitorIfNeeded()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard PaneFirstClickFocusSettings.isEnabled(),
              window?.isKeyWindow != true,
              bounds.contains(point) else { return nil }
        return self
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        PaneFirstClickFocusSettings.isEnabled()
    }

    override func mouseDown(with event: NSEvent) {
        onPointerDown?()
        forwardedMouseTarget = forwardedTarget(for: event)
        forwardedMouseTarget?.mouseDown(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        forwardedMouseTarget?.mouseDragged(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        forwardedMouseTarget?.mouseUp(with: event)
        forwardedMouseTarget = nil
    }

    func shouldHandle(_ event: NSEvent) -> Bool {
        guard event.type == .leftMouseDown,
              let window,
              event.window === window,
              !isHiddenOrHasHiddenAncestor else { return false }
        if PaneFirstClickFocusSettings.isEnabled(), window.isKeyWindow != true {
            return false
        }
        let point = convert(event.locationInWindow, from: nil)
        return bounds.contains(point)
    }

    func handleEventIfNeeded(_ event: NSEvent) -> NSEvent {
        guard shouldHandle(event) else { return event }
        DispatchQueue.main.async { [weak self] in
            self?.onPointerDown?()
        }
        return event
    }

    private func installEventMonitorIfNeeded() {
        guard eventMonitor == nil else { return }
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] event in
            self?.handleEventIfNeeded(event) ?? event
        }
    }

    private func forwardedTarget(for event: NSEvent) -> NSView? {
        guard let window else {
            return nil
        }
        guard let contentView = window.contentView else {
            return nil
        }
        isHidden = true
        defer { isHidden = false }
        let point = contentView.convert(event.locationInWindow, from: nil)
        let target = contentView.hitTest(point)
        return target === self ? nil : target
    }
}
