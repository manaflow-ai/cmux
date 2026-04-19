import AppKit
import SwiftUI
import STTextView

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
        MarkdownPanelTextSurface(
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

struct MarkdownPanelTextSurface: NSViewRepresentable {
    let markdown: String
    let ghosttyConfig: GhosttyConfig
    let isFocused: Bool

    func makeNSView(context: Context) -> MarkdownPanelSTTextContainerView {
        let view = MarkdownPanelSTTextContainerView()
        view.update(markdown: markdown, ghosttyConfig: ghosttyConfig, isFocused: isFocused)
        return view
    }

    func updateNSView(_ nsView: MarkdownPanelSTTextContainerView, context: Context) {
        nsView.update(markdown: markdown, ghosttyConfig: ghosttyConfig, isFocused: isFocused)
    }
}

@MainActor
final class MarkdownPanelSTTextContainerView: NSView, STTextViewDelegate {
    let scrollView = MarkdownPanelSTTextView.scrollableTextView()
    let textView: MarkdownPanelSTTextView

    private var currentMarkdown = ""
    private var currentThemeKey = ""
    private var currentFocusState = false
    private var wantsFirstResponderWhenAttached = false

    override init(frame frameRect: NSRect) {
        guard let textView = scrollView.documentView as? MarkdownPanelSTTextView else {
            fatalError("Expected MarkdownPanelSTTextView document view")
        }
        self.textView = textView
        super.init(frame: frameRect)

        translatesAutoresizingMaskIntoConstraints = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        MarkdownPanelEditorConfiguration.configure(textView: textView, scrollView: scrollView)
        textView.textDelegate = self
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if wantsFirstResponderWhenAttached {
            focusTextViewIfNeeded()
        }
    }

    func update(markdown: String, ghosttyConfig: GhosttyConfig, isFocused: Bool) {
        let theme = MarkdownPanelTheme(config: ghosttyConfig)
        let themeChanged = theme.cacheKey != currentThemeKey
        let contentChanged = markdown != currentMarkdown
        let focusChanged = isFocused != currentFocusState

        guard themeChanged || contentChanged || focusChanged else {
            return
        }

        let previousOrigin = scrollView.contentView.bounds.origin
        let previousViewportHeight = scrollView.contentView.bounds.height
        let previousDocumentHeight = textView.frame.height
        let previousScrollRatio = markdownScrollRatio(
            originY: previousOrigin.y,
            documentHeight: previousDocumentHeight,
            viewportHeight: previousViewportHeight
        )

        MarkdownPanelEditorConfiguration.apply(theme: theme, to: textView, scrollView: scrollView)

        if themeChanged || contentChanged {
            textView.attributedText = MarkdownPanelAttributedRenderer.attributedString(markdown: markdown, theme: theme)
        }

        if contentChanged {
            restoreScrollPosition(previousRatio: previousScrollRatio)
            currentMarkdown = markdown
        } else if themeChanged {
            scrollView.contentView.scroll(to: previousOrigin)
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }

        currentThemeKey = theme.cacheKey
        currentFocusState = isFocused
        if isFocused && focusChanged {
            focusTextViewIfNeeded()
        } else if !isFocused {
            wantsFirstResponderWhenAttached = false
        }
    }

    func textView(_ textView: STTextView, shouldChangeTextIn affectedCharRange: NSTextRange, replacementString: String?) -> Bool {
        false
    }

    func textView(_ textView: STTextView, clickedOnLink link: Any, at location: any NSTextLocation) -> Bool {
        guard let url = MarkdownPanelLinkActivationPolicy.url(for: link) else {
            return true
        }
        guard MarkdownPanelLinkActivationPolicy.shouldOpenLink(
            modifierFlags: (textView as? MarkdownPanelSTTextView)?.lastMouseDownModifierFlags ?? []
        ) else {
            return true
        }
        NSWorkspace.shared.open(url)
        return true
    }

    private func markdownScrollRatio(originY: CGFloat, documentHeight: CGFloat, viewportHeight: CGFloat) -> CGFloat {
        let scrollableHeight = max(documentHeight - viewportHeight, 0)
        guard scrollableHeight > 0 else {
            return 0
        }
        return min(max(originY / scrollableHeight, 0), 1)
    }

    private func restoreScrollPosition(previousRatio: CGFloat) {
        let viewportHeight = scrollView.contentView.bounds.height
        let scrollableHeight = max(textView.frame.height - viewportHeight, 0)
        let restoredY = scrollableHeight * previousRatio
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: restoredY))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    private func focusTextViewIfNeeded() {
        guard let window else {
            wantsFirstResponderWhenAttached = true
            return
        }
        wantsFirstResponderWhenAttached = false
        guard window.firstResponder !== textView else {
            return
        }
        _ = window.makeFirstResponder(textView)
    }
}

final class MarkdownPanelSTTextView: STTextView {
    var lastMouseDownModifierFlags: NSEvent.ModifierFlags = []

    override func mouseDown(with event: NSEvent) {
        lastMouseDownModifierFlags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        super.mouseDown(with: event)
        lastMouseDownModifierFlags = []
    }
}

@MainActor
enum MarkdownPanelEditorConfiguration {
    static func configure(textView: STTextView, scrollView: NSScrollView) {
        textView.isEditable = false
        textView.isSelectable = true
        textView.highlightSelectedLine = false
        textView.showsLineNumbers = true
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.isIncrementalSearchingEnabled = true
        textView.textFinder.incrementalSearchingShouldDimContentView = true

        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
    }

    static func apply(theme: MarkdownPanelTheme, to textView: STTextView, scrollView: NSScrollView) {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineBreakMode = .byWordWrapping
        paragraphStyle.lineSpacing = 3
        paragraphStyle.paragraphSpacing = 8

        textView.defaultParagraphStyle = paragraphStyle
        textView.font = theme.font
        textView.textColor = theme.textColor
        textView.backgroundColor = theme.editorBackgroundColor
        textView.insertionPointColor = theme.linkColor

        scrollView.backgroundColor = theme.editorBackgroundColor

        if let gutterView = textView.gutterView {
            gutterView.font = theme.lineNumberFont
            gutterView.textColor = theme.lineNumberColor
            gutterView.selectedLineTextColor = theme.lineNumberColor
            gutterView.selectedLineHighlightColor = theme.editorBackgroundColor
            gutterView.separatorColor = theme.gutterBackgroundColor
            gutterView.drawSeparator = false
            gutterView.highlightSelectedLine = false
            gutterView.minimumThickness = 44
        }
    }
}

struct MarkdownPanelTheme {
    let cacheKey: String
    let font: NSFont
    let lineNumberFont: NSFont
    let textColor: NSColor
    let secondaryTextColor: NSColor
    let tertiaryTextColor: NSColor
    let headingColor: NSColor
    let linkColor: NSColor
    let quoteColor: NSColor
    let codeColor: NSColor
    let codeBackgroundColor: NSColor
    let separatorColor: NSColor
    let editorBackgroundColor: NSColor
    let gutterBackgroundColor: NSColor
    let lineNumberColor: NSColor
    let strongFont: NSFont
    let emphasisFont: NSFont
    let codeFont: NSFont

    private let headingFonts: [NSFont]

    init(config: GhosttyConfig) {
        let isLightBackground = config.backgroundColor.isLightColor
        let baseFont = Self.font(family: config.fontFamily, size: config.fontSize, weight: .regular)
        let baseLineNumberFont = Self.font(
            family: config.fontFamily,
            size: max(config.fontSize - 1, 10),
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
        lineNumberFont = baseLineNumberFont
        strongFont = NSFontManager.shared.convert(baseFont, toHaveTrait: .boldFontMask)
        emphasisFont = NSFontManager.shared.convert(baseFont, toHaveTrait: .italicFontMask)
        codeFont = Self.font(family: config.fontFamily, size: config.fontSize, weight: .regular)

        editorBackgroundColor = config.backgroundColor
        gutterBackgroundColor = config.backgroundColor
        textColor = config.foregroundColor
        secondaryTextColor = config.foregroundColor.blended(withFraction: 0.28, of: config.backgroundColor) ?? config.foregroundColor
        tertiaryTextColor = config.foregroundColor.blended(withFraction: 0.5, of: config.backgroundColor) ?? config.foregroundColor
        lineNumberColor = tertiaryTextColor
        headingColor = config.palette[5] ?? config.palette[13] ?? config.foregroundColor
        linkColor = config.palette[4] ?? config.palette[12] ?? config.foregroundColor
        quoteColor = secondaryTextColor
        codeColor = config.palette[2] ?? config.palette[10] ?? config.foregroundColor
        codeBackgroundColor = config.backgroundColor.blended(
            withFraction: isLightBackground ? 0.18 : 0.28,
            of: config.selectionBackground
        ) ?? config.selectionBackground
        separatorColor = tertiaryTextColor

        headingFonts = (1...6).map { level in
            let size = baseFont.pointSize + CGFloat(7 - level) * 2.6
            return Self.font(
                family: config.fontFamily,
                size: size,
                weight: level <= 2 ? .bold : .semibold
            )
        }
    }

    func headingFont(for level: Int) -> NSFont {
        headingFonts[max(0, min(headingFonts.count - 1, level - 1))]
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

    static func attributedString(markdown: String, theme: MarkdownPanelTheme) -> NSAttributedString {
        let source = markdown as NSString
        let fullRange = NSRange(location: 0, length: source.length)
        let attributed = NSMutableAttributedString(
            string: markdown,
            attributes: [
                .font: theme.font,
                .foregroundColor: theme.textColor,
                .paragraphStyle: paragraphStyle(
                    lineSpacing: 3,
                    paragraphSpacing: 8,
                    paragraphSpacingBefore: 0
                )
            ]
        )
        let excludedInlineRanges = NSMutableArray()

        var isInsideFencedCodeBlock = false
        var location = 0
        while location < source.length {
            let lineRange = source.lineRange(for: NSRange(location: location, length: 0))
            let lineContentRange = trimmedLineContentRange(for: lineRange, in: source)
            let lineText = source.substring(with: lineContentRange)

            if matches(fenceRegex, lineText) {
                excludedInlineRanges.add(NSValue(range: lineContentRange))
                attributed.addAttributes(
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
                attributed.addAttributes(
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
                attributed.addAttribute(.foregroundColor, value: theme.tertiaryTextColor, range: hashRange)
                attributed.addAttributes(
                    [
                        .font: theme.headingFont(for: heading.level),
                        .foregroundColor: theme.headingColor
                    ],
                    range: titleRange
                )
                attributed.addAttribute(
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

            if matches(blockQuoteRegex, lineText) {
                attributed.addAttributes(
                    [
                        .foregroundColor: theme.quoteColor,
                        .paragraphStyle: paragraphStyle(lineSpacing: 3, paragraphSpacing: 8, paragraphSpacingBefore: 0)
                    ],
                    range: lineRange
                )
            } else if matches(thematicBreakRegex, lineText) {
                attributed.addAttributes(
                    [
                        .foregroundColor: theme.separatorColor,
                        .paragraphStyle: paragraphStyle(lineSpacing: 2, paragraphSpacing: 12, paragraphSpacingBefore: 6)
                    ],
                    range: lineRange
                )
            } else if lineText.contains("|") {
                attributed.addAttributes(
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
                attributed.addAttribute(.foregroundColor, value: theme.tertiaryTextColor, range: absoluteMarkerRange)
            }

            location = NSMaxRange(lineRange)
        }

        applyStrongAttributes(to: attributed, in: fullRange, theme: theme, excludedRanges: excludedInlineRanges)
        applyEmphasisAttributes(to: attributed, in: fullRange, theme: theme, excludedRanges: excludedInlineRanges)
        applyInlineCodeAttributes(to: attributed, in: fullRange, theme: theme, excludedRanges: excludedInlineRanges)
        applyLinkAttributes(to: attributed, markdown: source, in: fullRange, theme: theme, excludedRanges: excludedInlineRanges)

        return attributed
    }

    private static func applyStrongAttributes(
        to attributed: NSMutableAttributedString,
        in fullRange: NSRange,
        theme: MarkdownPanelTheme,
        excludedRanges: NSMutableArray
    ) {
        strongRegex.enumerateMatches(in: attributed.string, range: fullRange) { match, _, _ in
            guard let range = match?.range, range.length > 0 else { return }
            guard !intersectsExcludedRanges(range, excludedRanges: excludedRanges) else { return }
            attributed.addAttribute(.font, value: theme.strongFont, range: range)
        }
    }

    private static func applyEmphasisAttributes(
        to attributed: NSMutableAttributedString,
        in fullRange: NSRange,
        theme: MarkdownPanelTheme,
        excludedRanges: NSMutableArray
    ) {
        emphasisRegex.enumerateMatches(in: attributed.string, range: fullRange) { match, _, _ in
            guard let range = match?.range, range.length > 0 else { return }
            guard !intersectsExcludedRanges(range, excludedRanges: excludedRanges) else { return }
            attributed.addAttribute(.font, value: theme.emphasisFont, range: range)
        }
    }

    private static func applyInlineCodeAttributes(
        to attributed: NSMutableAttributedString,
        in fullRange: NSRange,
        theme: MarkdownPanelTheme,
        excludedRanges: NSMutableArray
    ) {
        inlineCodeRegex.enumerateMatches(in: attributed.string, range: fullRange) { match, _, _ in
            guard let range = match?.range, range.length > 0 else { return }
            guard !intersectsExcludedRanges(range, excludedRanges: excludedRanges) else { return }
            attributed.addAttributes(
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
        to attributed: NSMutableAttributedString,
        markdown: NSString,
        in fullRange: NSRange,
        theme: MarkdownPanelTheme,
        excludedRanges: NSMutableArray
    ) {
        markdownLinkRegex.enumerateMatches(in: markdown as String, range: fullRange) { match, _, _ in
            guard let match else { return }
            guard !intersectsExcludedRanges(match.range, excludedRanges: excludedRanges) else { return }
            let urlString = markdown.substring(with: match.range(at: 2))
            guard let url = URL(string: urlString) else { return }
            attributed.addAttributes(
                [
                    .foregroundColor: theme.linkColor,
                    .underlineStyle: NSUnderlineStyle.single.rawValue,
                    .link: url
                ],
                range: match.range
            )
        }

        autolinkRegex.enumerateMatches(in: markdown as String, range: fullRange) { match, _, _ in
            guard let match else { return }
            guard !intersectsExcludedRanges(match.range, excludedRanges: excludedRanges) else { return }
            let urlString = markdown.substring(with: match.range(at: 1))
            guard let url = URL(string: urlString) else { return }
            attributed.addAttributes(
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
        if let match = taskListRegex.firstMatch(in: lineText, range: fullRange) {
            return match.range
        }
        if let match = unorderedListRegex.firstMatch(in: lineText, range: fullRange) {
            return match.range
        }
        if let match = orderedListRegex.firstMatch(in: lineText, range: fullRange) {
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
        try! NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines])
    }
}

enum MarkdownPanelLinkActivationPolicy {
    static func shouldOpenLink(modifierFlags: NSEvent.ModifierFlags) -> Bool {
        modifierFlags.contains(.command)
    }

    static func url(for value: Any) -> URL? {
        switch value {
        case let url as URL:
            return url
        case let string as String:
            return URL(string: string)
        default:
            return nil
        }
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
        guard let window, let contentView = window.contentView else {
            return nil
        }
        isHidden = true
        defer { isHidden = false }
        let point = contentView.convert(event.locationInWindow, from: nil)
        let target = contentView.hitTest(point)
        return target === self ? nil : target
    }
}
