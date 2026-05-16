import AppKit
import SwiftUI

struct MarkdownEditorView: View {
    @ObservedObject var panel: MarkdownPanel
    let isVisibleInUI: Bool
    let appearance: PanelAppearance
    let onRequestPanelFocus: () -> Void

    @State private var editorHandle = MarkdownEditorHandle()
    @State private var renderer = MarkdownWebRendererHandle()
    @State private var showsOutline = true
    @State private var showsLivePreview = true
    @State private var wrapsLines = true

    private var outline: [MarkdownEditorHeading] {
        MarkdownEditorOutline.headings(in: panel.textContent)
    }

    private var stats: MarkdownEditorStats {
        MarkdownEditorStats(markdown: panel.textContent)
    }

    var body: some View {
        GeometryReader { proxy in
            VStack(spacing: 0) {
                toolbar(availableWidth: proxy.size.width)
                Divider()
                editorBody(availableWidth: proxy.size.width)
                Divider()
                statusBar
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(nsColor: appearance.contentBackgroundColor))
    }

    @ViewBuilder
    private func editorBody(availableWidth: CGFloat) -> some View {
        HStack(spacing: 0) {
            if showsOutline, availableWidth >= 720 {
                outlineView
                    .frame(width: min(240, max(176, availableWidth * 0.22)))
                Divider()
            }

            MarkdownSourceEditor(
                panel: panel,
                handle: editorHandle,
                isVisibleInUI: isVisibleInUI,
                themeBackgroundColor: appearance.contentBackgroundColor,
                themeForegroundColor: appearance.foregroundColor,
                drawsBackground: appearance.drawsContentBackground,
                wrapsLines: wrapsLines,
                onRequestPanelFocus: onRequestPanelFocus
            )
            .frame(minWidth: 260, maxWidth: .infinity, maxHeight: .infinity)

            if showsLivePreview, availableWidth >= 900 {
                Divider()
                livePreview
                    .frame(minWidth: 280, idealWidth: availableWidth * 0.42, maxWidth: .infinity)
            }
        }
    }

    private var outlineView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                if outline.isEmpty {
                    Text(String(localized: "markdown.editor.outline.empty", defaultValue: "No headings"))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    ForEach(outline) { heading in
                        Button {
                            editorHandle.jump(to: heading)
                        } label: {
                            HStack(spacing: 6) {
                                Text(String(repeating: " ", count: max(0, heading.level - 1)))
                                    .font(.system(size: 11, design: .monospaced))
                                Text(heading.title)
                                    .font(.system(size: 11, weight: heading.level <= 2 ? .semibold : .regular))
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                Spacer(minLength: 0)
                            }
                            .padding(.vertical, 5)
                            .padding(.leading, 10 + CGFloat(max(0, heading.level - 1)) * 10)
                            .padding(.trailing, 8)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Color(nsColor: appearance.foregroundColor))
                        .help(heading.title)
                        .accessibilityLabel(heading.title)
                    }
                }
            }
            .padding(.vertical, 6)
        }
        .background(Color(nsColor: appearance.contentBackgroundColor).opacity(0.72))
        .accessibilityLabel(String(localized: "markdown.editor.outline.accessibility", defaultValue: "Markdown outline"))
    }

    private var livePreview: some View {
        MarkdownWebRenderer(
            markdown: panel.content,
            theme: MarkdownWebTheme.resolve(backgroundColor: appearance.backgroundColor),
            backgroundColor: appearance.contentBackgroundColor,
            panelId: panel.id,
            workspaceId: panel.workspaceId,
            filePath: panel.filePath,
            handle: renderer,
            onRequestPanelFocus: onRequestPanelFocus
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func toolbar(availableWidth: CGFloat) -> some View {
        HStack(spacing: 7) {
            toolbarButton(
                systemName: showsOutline ? "sidebar.left" : "sidebar.left",
                label: String(localized: "markdown.editor.toolbar.toggleOutline", defaultValue: "Toggle Outline"),
                isSelected: showsOutline,
                action: { showsOutline.toggle() }
            )
            .disabled(availableWidth < 720)

            toolbarButton(
                systemName: "rectangle.split.2x1",
                label: String(localized: "markdown.editor.toolbar.togglePreview", defaultValue: "Toggle Live Preview"),
                isSelected: showsLivePreview,
                action: { showsLivePreview.toggle() }
            )
            .disabled(availableWidth < 900)

            toolbarButton(
                systemName: "arrow.left.and.right.text.vertical",
                label: String(localized: "markdown.editor.toolbar.toggleWrap", defaultValue: "Toggle Line Wrap"),
                isSelected: wrapsLines,
                action: { wrapsLines.toggle() }
            )

            toolbarDivider

            toolbarButton(
                systemName: "textformat.size",
                label: String(localized: "markdown.editor.toolbar.heading", defaultValue: "Heading"),
                action: { editorHandle.apply(.heading) }
            )
            toolbarButton(
                systemName: "bold",
                label: String(localized: "markdown.editor.toolbar.bold", defaultValue: "Bold"),
                action: { editorHandle.apply(.bold) }
            )
            toolbarButton(
                systemName: "italic",
                label: String(localized: "markdown.editor.toolbar.italic", defaultValue: "Italic"),
                action: { editorHandle.apply(.italic) }
            )
            toolbarButton(
                systemName: "chevron.left.forwardslash.chevron.right",
                label: String(localized: "markdown.editor.toolbar.code", defaultValue: "Code"),
                action: { editorHandle.apply(.code) }
            )
            toolbarButton(
                systemName: "link",
                label: String(localized: "markdown.editor.toolbar.link", defaultValue: "Link"),
                action: { editorHandle.apply(.link) }
            )
            toolbarButton(
                systemName: "checklist",
                label: String(localized: "markdown.editor.toolbar.task", defaultValue: "Task List"),
                action: { editorHandle.apply(.taskList) }
            )
            toolbarButton(
                systemName: "tablecells",
                label: String(localized: "markdown.editor.toolbar.table", defaultValue: "Table"),
                action: { editorHandle.apply(.table) }
            )

            Spacer(minLength: 8)

            toolbarButton(
                systemName: "text.cursor",
                label: String(localized: "markdown.editor.toolbar.focus", defaultValue: "Focus Editor"),
                action: { editorHandle.focus() }
            )
        }
        .padding(.horizontal, 10)
        .frame(height: 32)
        .background(Color(nsColor: appearance.contentBackgroundColor).opacity(0.94))
    }

    private var toolbarDivider: some View {
        Rectangle()
            .fill(Color.secondary.opacity(0.25))
            .frame(width: 1, height: 18)
            .padding(.horizontal, 2)
    }

    private func toolbarButton(
        systemName: String,
        label: String,
        isSelected: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .resizable()
                .scaledToFit()
                .frame(width: 13, height: 13)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(isSelected ? cmuxAccentColor().opacity(0.18) : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .foregroundStyle(isSelected ? cmuxAccentColor() : Color.secondary)
        .help(label)
        .accessibilityLabel(label)
    }

    private var statusBar: some View {
        HStack(spacing: 14) {
            Label("\(stats.lineCount)", systemImage: "text.alignleft")
                .help(String(localized: "markdown.editor.stats.lines", defaultValue: "Lines"))
            Label("\(stats.wordCount)", systemImage: "text.word.spacing")
                .help(String(localized: "markdown.editor.stats.words", defaultValue: "Words"))
            Label("\(outline.count)", systemImage: "list.bullet.indent")
                .help(String(localized: "markdown.editor.stats.headings", defaultValue: "Headings"))
            Spacer(minLength: 8)
            if panel.isDirty {
                Text(String(localized: "markdown.editor.status.unsaved", defaultValue: "Unsaved"))
                    .foregroundStyle(cmuxAccentColor())
            } else {
                Text(String(localized: "markdown.editor.status.saved", defaultValue: "Saved"))
                    .foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .frame(height: 24)
        .background(Color(nsColor: appearance.contentBackgroundColor).opacity(0.94))
    }
}

@MainActor
final class MarkdownEditorHandle {
    weak var textView: MarkdownSourceTextView?

    func apply(_ command: MarkdownEditorCommand) {
        textView?.applyMarkdownCommand(command)
    }

    func jump(to heading: MarkdownEditorHeading) {
        guard let textView else { return }
        let location = min(heading.location, (textView.string as NSString).length)
        textView.window?.makeFirstResponder(textView)
        textView.setSelectedRange(NSRange(location: location, length: 0))
        textView.scrollRangeToVisible(NSRange(location: location, length: 0))
    }

    func focus() {
        guard let textView else { return }
        textView.window?.makeFirstResponder(textView)
    }
}

struct MarkdownSourceEditor: NSViewRepresentable {
    @ObservedObject var panel: MarkdownPanel
    let handle: MarkdownEditorHandle
    let isVisibleInUI: Bool
    let themeBackgroundColor: NSColor
    let themeForegroundColor: NSColor
    let drawsBackground: Bool
    let wrapsLines: Bool
    let onRequestPanelFocus: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(panel: panel)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.isHidden = !isVisibleInUI
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = drawsBackground

        let textView = MarkdownSourceTextView()
        textView.panel = panel
        textView.onRequestPanelFocus = onRequestPanelFocus
        textView.delegate = context.coordinator
        textView.isEditable = true
        textView.isSelectable = true
        textView.allowsUndo = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.usesFindPanel = true
        textView.usesFontPanel = false
        textView.drawsBackground = drawsBackground
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = true
        textView.autoresizingMask = [.width]
        textView.applyFilePreviewTextEditorInsets()
        textView.string = panel.textContent
        textView.configure(
            backgroundColor: themeBackgroundColor,
            foregroundColor: themeForegroundColor,
            drawsBackground: drawsBackground,
            wrapsLines: wrapsLines
        )
        panel.attachTextView(textView)
        handle.textView = textView

        scrollView.documentView = textView
        applyTheme(
            scrollView,
            backgroundColor: themeBackgroundColor,
            foregroundColor: themeForegroundColor,
            drawsBackground: drawsBackground
        )
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.panel = panel
        scrollView.isHidden = !isVisibleInUI
        applyTheme(
            scrollView,
            backgroundColor: themeBackgroundColor,
            foregroundColor: themeForegroundColor,
            drawsBackground: drawsBackground
        )

        guard let textView = scrollView.documentView as? MarkdownSourceTextView else { return }
        textView.panel = panel
        textView.onRequestPanelFocus = onRequestPanelFocus
        textView.applyFilePreviewTextEditorInsets()
        textView.configure(
            backgroundColor: themeBackgroundColor,
            foregroundColor: themeForegroundColor,
            drawsBackground: drawsBackground,
            wrapsLines: wrapsLines
        )
        panel.attachTextView(textView)
        handle.textView = textView

        guard textView.string != panel.textContent else {
            textView.highlightMarkdown()
            return
        }
        context.coordinator.isApplyingPanelUpdate = true
        textView.string = panel.textContent
        textView.highlightMarkdown()
        context.coordinator.isApplyingPanelUpdate = false
    }

    private func applyTheme(
        _ scrollView: NSScrollView,
        backgroundColor: NSColor,
        foregroundColor: NSColor,
        drawsBackground: Bool
    ) {
        let resolvedBackgroundColor = drawsBackground ? backgroundColor : .clear
        scrollView.drawsBackground = drawsBackground
        scrollView.backgroundColor = resolvedBackgroundColor
        scrollView.contentView.drawsBackground = drawsBackground
        scrollView.contentView.backgroundColor = resolvedBackgroundColor
        if let textView = scrollView.documentView as? MarkdownSourceTextView {
            textView.textColor = foregroundColor
            textView.insertionPointColor = foregroundColor
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var panel: MarkdownPanel
        var isApplyingPanelUpdate = false

        init(panel: MarkdownPanel) {
            self.panel = panel
        }

        func textDidChange(_ notification: Notification) {
            guard !isApplyingPanelUpdate,
                  let textView = notification.object as? MarkdownSourceTextView else { return }
            panel.updateTextContent(textView.string)
            textView.highlightMarkdown()
        }
    }
}

final class MarkdownSourceTextView: NSTextView {
    weak var panel: MarkdownPanel?
    var onRequestPanelFocus: (() -> Void)?

    private static let defaultEditorFontSize: CGFloat = 14
    private static let minimumEditorFontSize: CGFloat = 9
    private static let maximumEditorFontSize: CGFloat = 38

    private var editorFontSize = defaultEditorFontSize
    private var pendingSaveShortcutChordPrefix: ShortcutStroke?
    private var palette = MarkdownEditorPalette.light(foregroundColor: .labelColor)
    private var wrapsLines = true

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyFilePreviewTextEditorInsets()
        panel?.retryPendingFocus()
    }

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result {
            onRequestPanelFocus?()
        }
        return result
    }

    func configure(
        backgroundColor: NSColor,
        foregroundColor: NSColor,
        drawsBackground: Bool,
        wrapsLines: Bool
    ) {
        self.wrapsLines = wrapsLines
        palette = MarkdownEditorPalette.resolve(backgroundColor: backgroundColor, foregroundColor: foregroundColor)
        self.drawsBackground = drawsBackground
        self.backgroundColor = drawsBackground ? backgroundColor : .clear
        textColor = foregroundColor
        insertionPointColor = foregroundColor
        updateTextContainerSizing()
        highlightMarkdown()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown else {
            return super.performKeyEquivalent(with: event)
        }
        guard let shouldSave = saveShortcutMatch(for: event) else {
            return super.performKeyEquivalent(with: event)
        }
        if shouldSave {
            panel?.saveTextContent()
        }
        return true
    }

    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command),
           let characters = event.charactersIgnoringModifiers?.lowercased() {
            switch characters {
            case "b":
                applyMarkdownCommand(.bold)
                return
            case "i":
                applyMarkdownCommand(.italic)
                return
            case "k":
                applyMarkdownCommand(.link)
                return
            default:
                break
            }
        }
        super.keyDown(with: event)
    }

    override func insertNewline(_ sender: Any?) {
        if let edit = MarkdownEditorTextCommands.continuationEdit(
            markdown: string,
            selectedRange: selectedRange()
        ) {
            apply(edit)
            return
        }
        super.insertNewline(sender)
    }

    override func mouseDown(with event: NSEvent) {
        onRequestPanelFocus?()

        let point = convert(event.locationInWindow, from: nil)
        let index = characterIndex(at: point)

        if event.clickCount == 1,
           let edit = MarkdownEditorTextCommands.checkboxToggleEdit(markdown: string, characterIndex: index) {
            apply(edit)
            return
        }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command),
           let target = MarkdownEditorLinkDetector.linkTarget(in: string, characterIndex: index),
           panel?.openLinkedMarkdownFile(rawPath: target) == true {
            return
        }

        super.mouseDown(with: event)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .iBeam)
    }

    override func magnify(with event: NSEvent) {
        let factor = 1.0 + event.magnification
        guard factor.isFinite, factor > 0 else { return }
        adjustEditorFontSize(by: factor)
    }

    override func scrollWheel(with event: NSEvent) {
        guard FilePreviewInteraction.hasZoomModifier(event) else {
            super.scrollWheel(with: event)
            return
        }
        adjustEditorFontSize(by: FilePreviewInteraction.zoomFactor(forScroll: event))
    }

    override func smartMagnify(with event: NSEvent) {
        if editorFontSize == Self.defaultEditorFontSize {
            setEditorFontSize(18)
        } else {
            setEditorFontSize(Self.defaultEditorFontSize)
        }
    }

    func applyMarkdownCommand(_ command: MarkdownEditorCommand) {
        guard let edit = MarkdownEditorTextCommands.edit(
            command: command,
            markdown: string,
            selectedRange: selectedRange()
        ) else { return }
        apply(edit)
    }

    func highlightMarkdown() {
        MarkdownSyntaxHighlighter.highlight(textView: self, palette: palette, fontSize: editorFontSize)
    }

    private func apply(_ edit: MarkdownTextEdit) {
        guard shouldChangeText(in: edit.replacementRange, replacementString: edit.replacement) else {
            return
        }
        textStorage?.replaceCharacters(in: edit.replacementRange, with: edit.replacement)
        didChangeText()
        let documentLength = (string as NSString).length
        let selected = NSRange(
            location: min(edit.selectedRange.location, documentLength),
            length: min(edit.selectedRange.length, max(0, documentLength - edit.selectedRange.location))
        )
        setSelectedRange(selected)
        scrollRangeToVisible(selected)
    }

    private func characterIndex(at point: NSPoint) -> Int {
        guard let layoutManager, let textContainer else {
            return (string as NSString).length
        }
        let containerOrigin = textContainerOrigin
        let containerPoint = NSPoint(x: point.x - containerOrigin.x, y: point.y - containerOrigin.y)
        var fraction: CGFloat = 0
        let index = layoutManager.characterIndex(
            for: containerPoint,
            in: textContainer,
            fractionOfDistanceBetweenInsertionPoints: &fraction
        )
        return min(max(0, index), (string as NSString).length)
    }

    private func updateTextContainerSizing() {
        guard let textContainer else { return }
        if wrapsLines {
            isHorizontallyResizable = false
            textContainer.widthTracksTextView = true
            textContainer.containerSize = NSSize(
                width: max(0, enclosingScrollView?.contentSize.width ?? bounds.width),
                height: CGFloat.greatestFiniteMagnitude
            )
            maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        } else {
            isHorizontallyResizable = true
            textContainer.widthTracksTextView = false
            textContainer.containerSize = NSSize(
                width: CGFloat.greatestFiniteMagnitude,
                height: CGFloat.greatestFiniteMagnitude
            )
            maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        }
    }

    private func adjustEditorFontSize(by factor: CGFloat) {
        setEditorFontSize(editorFontSize * factor)
    }

    private func setEditorFontSize(_ nextFontSize: CGFloat) {
        let clamped = min(max(nextFontSize, Self.minimumEditorFontSize), Self.maximumEditorFontSize)
        guard clamped.isFinite else { return }
        editorFontSize = clamped
        highlightMarkdown()
    }

    private func saveShortcutMatch(for event: NSEvent) -> Bool? {
        let shortcut = KeyboardShortcutSettings.shortcut(for: .saveFilePreview)
        guard shortcut.hasChord else {
            pendingSaveShortcutChordPrefix = nil
            return shortcut.matches(event: event) ? true : nil
        }

        if let pendingPrefix = pendingSaveShortcutChordPrefix {
            pendingSaveShortcutChordPrefix = nil
            guard pendingPrefix == shortcut.firstStroke,
                  let secondStroke = shortcut.secondStroke else {
                return nil
            }
            return secondStroke.matches(event: event) ? true : nil
        }

        if shortcut.firstStroke.matches(event: event) {
            pendingSaveShortcutChordPrefix = shortcut.firstStroke
            return false
        }
        return nil
    }
}

enum MarkdownEditorCommand {
    case heading
    case bold
    case italic
    case code
    case link
    case taskList
    case table
}

struct MarkdownTextEdit: Equatable {
    let replacementRange: NSRange
    let replacement: String
    let selectedRange: NSRange
}

struct MarkdownEditorHeading: Identifiable, Equatable {
    let level: Int
    let title: String
    let location: Int

    var id: String {
        "\(location)-\(level)-\(title)"
    }
}

enum MarkdownEditorOutline {
    static func headings(in markdown: String) -> [MarkdownEditorHeading] {
        let ns = markdown as NSString
        let lines = markdownLineRanges(in: markdown)
        var headings: [MarkdownEditorHeading] = []
        var inFence = false
        var previousContentLine: (range: NSRange, text: String)?

        for lineRange in lines {
            let line = ns.substring(with: lineRange)
            let trimmedNewline = line.trimmingCharacters(in: .newlines)
            let trimmed = trimmedNewline.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                inFence.toggle()
                previousContentLine = nil
                continue
            }

            guard !inFence else { continue }

            if let heading = atxHeading(line: trimmedNewline, location: lineRange.location) {
                headings.append(heading)
                previousContentLine = nil
                continue
            }

            if let previousHeadingCandidate = previousContentLine,
               let level = setextHeadingLevel(marker: trimmed) {
                let title = previousHeadingCandidate.text.trimmingCharacters(in: .whitespaces)
                if !title.isEmpty {
                    headings.append(MarkdownEditorHeading(
                        level: level,
                        title: title,
                        location: previousHeadingCandidate.range.location
                    ))
                }
                previousContentLine = nil
                continue
            }

            if trimmed.isEmpty || trimmed.hasPrefix(">") || trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                previousContentLine = nil
            } else {
                previousContentLine = (lineRange, trimmedNewline)
            }
        }

        return headings
    }

    private static func atxHeading(line: String, location: Int) -> MarkdownEditorHeading? {
        let pattern = #"^\s{0,3}(#{1,6})\s+(.+?)\s*#*\s*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)),
              let markerRange = Range(match.range(at: 1), in: line),
              let titleRange = Range(match.range(at: 2), in: line) else {
            return nil
        }
        let level = line[markerRange].count
        let title = String(line[titleRange]).trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else { return nil }
        return MarkdownEditorHeading(level: level, title: title, location: location)
    }

    private static func setextHeadingLevel(marker: String) -> Int? {
        guard marker.count >= 2 else { return nil }
        if marker.allSatisfy({ $0 == "=" }) {
            return 1
        }
        if marker.allSatisfy({ $0 == "-" }) {
            return 2
        }
        return nil
    }
}

struct MarkdownEditorStats: Equatable {
    let lineCount: Int
    let wordCount: Int

    init(markdown: String) {
        lineCount = markdown.isEmpty ? 1 : markdown.split(separator: "\n", omittingEmptySubsequences: false).count
        let regex = try? NSRegularExpression(pattern: #"[A-Za-z0-9_]+(?:[-'][A-Za-z0-9_]+)*"#)
        wordCount = regex?.numberOfMatches(
            in: markdown,
            range: NSRange(location: 0, length: (markdown as NSString).length)
        ) ?? 0
    }
}

enum MarkdownEditorTextCommands {
    static func edit(command: MarkdownEditorCommand, markdown: String, selectedRange: NSRange) -> MarkdownTextEdit? {
        switch command {
        case .heading:
            return prefixSelectedLines(markdown: markdown, selectedRange: selectedRange, prefix: "## ")
        case .bold:
            return wrapSelection(markdown: markdown, selectedRange: selectedRange, prefix: "**", suffix: "**", placeholder: "strong text")
        case .italic:
            return wrapSelection(markdown: markdown, selectedRange: selectedRange, prefix: "_", suffix: "_", placeholder: "emphasis")
        case .code:
            let selected = (markdown as NSString).substring(with: selectedRange)
            if selected.contains("\n") {
                return wrapSelection(markdown: markdown, selectedRange: selectedRange, prefix: "```\n", suffix: "\n```", placeholder: "code")
            }
            return wrapSelection(markdown: markdown, selectedRange: selectedRange, prefix: "`", suffix: "`", placeholder: "code")
        case .link:
            return linkEdit(markdown: markdown, selectedRange: selectedRange)
        case .taskList:
            return prefixSelectedLines(markdown: markdown, selectedRange: selectedRange, prefix: "- [ ] ")
        case .table:
            return tableEdit(markdown: markdown, selectedRange: selectedRange)
        }
    }

    static func continuationEdit(markdown: String, selectedRange: NSRange) -> MarkdownTextEdit? {
        guard selectedRange.length == 0 else { return nil }
        let ns = markdown as NSString
        let lineRange = ns.lineRange(for: NSRange(location: min(selectedRange.location, ns.length), length: 0))
        let line = ns.substring(with: NSRange(location: lineRange.location, length: max(0, selectedRange.location - lineRange.location)))
        let trimmedLine = line.trimmingCharacters(in: .whitespaces)

        if let task = match(line: line, pattern: #"^(\s*)([-*+])\s+\[([ xX])\]\s*(.*)$"#) {
            let body = task[4].trimmingCharacters(in: .whitespaces)
            if body.isEmpty {
                return MarkdownTextEdit(
                    replacementRange: NSRange(location: lineRange.location, length: (line as NSString).length),
                    replacement: "",
                    selectedRange: NSRange(location: lineRange.location, length: 0)
                )
            }
            let insertion = "\n\(task[1])\(task[2]) [ ] "
            return insertionEdit(insertion, at: selectedRange.location)
        }

        if let unordered = match(line: line, pattern: #"^(\s*)([-*+])\s+(.*)$"#) {
            let body = unordered[3].trimmingCharacters(in: .whitespaces)
            if body.isEmpty || trimmedLine == unordered[1] + unordered[2] {
                return MarkdownTextEdit(
                    replacementRange: NSRange(location: lineRange.location, length: (line as NSString).length),
                    replacement: "",
                    selectedRange: NSRange(location: lineRange.location, length: 0)
                )
            }
            let insertion = "\n\(unordered[1])\(unordered[2]) "
            return insertionEdit(insertion, at: selectedRange.location)
        }

        if let ordered = match(line: line, pattern: #"^(\s*)(\d+)([.)])\s+(.*)$"#),
           let currentNumber = Int(ordered[2]) {
            let body = ordered[4].trimmingCharacters(in: .whitespaces)
            if body.isEmpty {
                return MarkdownTextEdit(
                    replacementRange: NSRange(location: lineRange.location, length: (line as NSString).length),
                    replacement: "",
                    selectedRange: NSRange(location: lineRange.location, length: 0)
                )
            }
            let insertion = "\n\(ordered[1])\(currentNumber + 1)\(ordered[3]) "
            return insertionEdit(insertion, at: selectedRange.location)
        }

        return nil
    }

    static func checkboxToggleEdit(markdown: String, characterIndex: Int) -> MarkdownTextEdit? {
        let ns = markdown as NSString
        guard ns.length > 0 else { return nil }
        let clamped = min(max(0, characterIndex), ns.length)
        let lineRange = ns.lineRange(for: NSRange(location: clamped, length: 0))
        let line = ns.substring(with: lineRange)
        guard let regex = try? NSRegularExpression(pattern: #"^(\s*[-*+]\s+\[)([ xX])(\])"#),
              let match = regex.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)) else {
            return nil
        }
        let checkboxRange = NSRange(
            location: lineRange.location + match.range(at: 1).location,
            length: match.range(at: 1).length + match.range(at: 2).length + match.range(at: 3).length
        )
        guard characterIndex >= checkboxRange.location,
              characterIndex <= checkboxRange.location + checkboxRange.length + 2 else {
            return nil
        }
        let stateRange = NSRange(location: lineRange.location + match.range(at: 2).location, length: 1)
        let current = ns.substring(with: stateRange)
        let next = current == " " ? "x" : " "
        return MarkdownTextEdit(
            replacementRange: stateRange,
            replacement: next,
            selectedRange: NSRange(location: stateRange.location + 1, length: 0)
        )
    }

    private static func wrapSelection(
        markdown: String,
        selectedRange: NSRange,
        prefix: String,
        suffix: String,
        placeholder: String
    ) -> MarkdownTextEdit {
        let ns = markdown as NSString
        let selected = selectedRange.length > 0 ? ns.substring(with: selectedRange) : placeholder
        let replacement = "\(prefix)\(selected)\(suffix)"
        let selectionLocation = selectedRange.location + (prefix as NSString).length
        let selectionLength = selectedRange.length > 0 ? selectedRange.length : (placeholder as NSString).length
        return MarkdownTextEdit(
            replacementRange: selectedRange,
            replacement: replacement,
            selectedRange: NSRange(location: selectionLocation, length: selectionLength)
        )
    }

    private static func linkEdit(markdown: String, selectedRange: NSRange) -> MarkdownTextEdit {
        let ns = markdown as NSString
        let selected = selectedRange.length > 0 ? ns.substring(with: selectedRange) : "label"
        let replacement = "[\(selected)]()"
        let cursor = selectedRange.location + (replacement as NSString).length - 1
        return MarkdownTextEdit(
            replacementRange: selectedRange,
            replacement: replacement,
            selectedRange: NSRange(location: cursor, length: 0)
        )
    }

    private static func tableEdit(markdown: String, selectedRange: NSRange) -> MarkdownTextEdit {
        let insertion = """

        | Column | Column |
        | --- | --- |
        | Value | Value |

        """
        let prefix = selectedRange.location > 0 && !(markdown as NSString).substring(with: NSRange(location: selectedRange.location - 1, length: 1)).contains("\n") ? "\n" : ""
        let replacement = prefix + insertion
        let selectedLocation = selectedRange.location + (prefix as NSString).length + 2
        return MarkdownTextEdit(
            replacementRange: selectedRange,
            replacement: replacement,
            selectedRange: NSRange(location: selectedLocation, length: 6)
        )
    }

    private static func prefixSelectedLines(markdown: String, selectedRange: NSRange, prefix: String) -> MarkdownTextEdit {
        let ns = markdown as NSString
        let lineRange = ns.lineRange(for: selectedRange)
        let selectedText = ns.substring(with: lineRange)
        let lines = selectedText.split(separator: "\n", omittingEmptySubsequences: false)
        let replacement = lines.enumerated().map { index, line in
            if index == lines.count - 1, line.isEmpty, selectedText.hasSuffix("\n") {
                return ""
            }
            let text = String(line)
            if text.trimmingCharacters(in: .whitespaces).isEmpty {
                return text
            }
            return prefix + text
        }.joined(separator: "\n")
        return MarkdownTextEdit(
            replacementRange: lineRange,
            replacement: replacement,
            selectedRange: NSRange(location: selectedRange.location + (prefix as NSString).length, length: selectedRange.length)
        )
    }

    private static func insertionEdit(_ insertion: String, at location: Int) -> MarkdownTextEdit {
        MarkdownTextEdit(
            replacementRange: NSRange(location: location, length: 0),
            replacement: insertion,
            selectedRange: NSRange(location: location + (insertion as NSString).length, length: 0)
        )
    }

    private static func match(line: String, pattern: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)) else {
            return nil
        }
        var captures: [String] = []
        for index in 0..<match.numberOfRanges {
            let range = match.range(at: index)
            guard range.location != NSNotFound else {
                captures.append("")
                continue
            }
            captures.append((line as NSString).substring(with: range))
        }
        return captures
    }
}

enum MarkdownEditorLinkDetector {
    static func linkTarget(in markdown: String, characterIndex: Int) -> String? {
        if let inline = inlineLinkTarget(in: markdown, characterIndex: characterIndex) {
            return inline
        }
        if let wiki = wikiLinkTarget(in: markdown, characterIndex: characterIndex) {
            return wiki
        }
        return rawMarkdownPath(in: markdown, characterIndex: characterIndex)
    }

    private static func inlineLinkTarget(in markdown: String, characterIndex: Int) -> String? {
        let pattern = #"\[[^\]\n]+\]\(([^)\n]+)\)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = markdown as NSString
        let fullRange = NSRange(location: 0, length: ns.length)
        var result: String?
        regex.enumerateMatches(in: markdown, range: fullRange) { match, _, stop in
            guard let match else { return }
            if NSLocationInRange(characterIndex, match.range),
               match.range(at: 1).location != NSNotFound {
                result = ns.substring(with: match.range(at: 1))
                stop.pointee = true
            }
        }
        return result?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func wikiLinkTarget(in markdown: String, characterIndex: Int) -> String? {
        let pattern = #"\[\[([^\]\n]+)\]\]"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = markdown as NSString
        let fullRange = NSRange(location: 0, length: ns.length)
        var result: String?
        regex.enumerateMatches(in: markdown, range: fullRange) { match, _, stop in
            guard let match else { return }
            if NSLocationInRange(characterIndex, match.range),
               match.range(at: 1).location != NSNotFound {
                var target = ns.substring(with: match.range(at: 1))
                if let pipe = target.firstIndex(of: "|") {
                    target = String(target[..<pipe])
                }
                target = target.trimmingCharacters(in: .whitespacesAndNewlines)
                if (target as NSString).pathExtension.isEmpty {
                    target += ".md"
                }
                result = target
                stop.pointee = true
            }
        }
        return result
    }

    private static func rawMarkdownPath(in markdown: String, characterIndex: Int) -> String? {
        let ns = markdown as NSString
        guard ns.length > 0 else { return nil }
        let clamped = min(max(0, characterIndex), ns.length - 1)
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~/:%+")
        func isAllowedCharacter(at index: Int) -> Bool {
            guard index >= 0, index < ns.length,
                  let scalar = UnicodeScalar(UInt32(ns.character(at: index))) else {
                return false
            }
            return allowed.contains(scalar)
        }
        var start = clamped
        while start > 0, isAllowedCharacter(at: start - 1) {
            start -= 1
        }
        var end = clamped
        while end < ns.length, isAllowedCharacter(at: end) {
            end += 1
        }
        let candidate = ns.substring(with: NSRange(location: start, length: end - start))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return MarkdownPanelFileLinkResolver.isMarkdownPathLike(candidate) ? candidate : nil
    }
}

struct MarkdownEditorPalette {
    let foreground: NSColor
    let muted: NSColor
    let heading: NSColor
    let emphasis: NSColor
    let code: NSColor
    let codeBackground: NSColor
    let link: NSColor
    let marker: NSColor
    let quote: NSColor
    let frontMatter: NSColor

    static func resolve(backgroundColor: NSColor, foregroundColor: NSColor) -> MarkdownEditorPalette {
        let background = backgroundColor.markdownOpaqueSRGB
        if background.isLightColor {
            return light(foregroundColor: foregroundColor)
        }
        return dark(foregroundColor: foregroundColor)
    }

    static func light(foregroundColor: NSColor) -> MarkdownEditorPalette {
        MarkdownEditorPalette(
            foreground: foregroundColor,
            muted: NSColor(srgbRed: 0.36, green: 0.39, blue: 0.43, alpha: 1),
            heading: NSColor(srgbRed: 0.05, green: 0.18, blue: 0.34, alpha: 1),
            emphasis: NSColor(srgbRed: 0.39, green: 0.18, blue: 0.58, alpha: 1),
            code: NSColor(srgbRed: 0.56, green: 0.16, blue: 0.10, alpha: 1),
            codeBackground: NSColor(srgbRed: 0.94, green: 0.95, blue: 0.96, alpha: 1),
            link: NSColor(srgbRed: 0.03, green: 0.34, blue: 0.69, alpha: 1),
            marker: NSColor(srgbRed: 0.48, green: 0.51, blue: 0.56, alpha: 1),
            quote: NSColor(srgbRed: 0.08, green: 0.42, blue: 0.32, alpha: 1),
            frontMatter: NSColor(srgbRed: 0.45, green: 0.30, blue: 0.12, alpha: 1)
        )
    }

    static func dark(foregroundColor: NSColor) -> MarkdownEditorPalette {
        MarkdownEditorPalette(
            foreground: foregroundColor,
            muted: NSColor(srgbRed: 0.56, green: 0.60, blue: 0.66, alpha: 1),
            heading: NSColor(srgbRed: 0.58, green: 0.78, blue: 1.00, alpha: 1),
            emphasis: NSColor(srgbRed: 0.88, green: 0.66, blue: 1.00, alpha: 1),
            code: NSColor(srgbRed: 1.00, green: 0.69, blue: 0.48, alpha: 1),
            codeBackground: NSColor(srgbRed: 0.15, green: 0.17, blue: 0.20, alpha: 1),
            link: NSColor(srgbRed: 0.46, green: 0.72, blue: 1.00, alpha: 1),
            marker: NSColor(srgbRed: 0.50, green: 0.54, blue: 0.60, alpha: 1),
            quote: NSColor(srgbRed: 0.48, green: 0.86, blue: 0.67, alpha: 1),
            frontMatter: NSColor(srgbRed: 0.94, green: 0.70, blue: 0.42, alpha: 1)
        )
    }
}

enum MarkdownSyntaxHighlighter {
    static func highlight(textView: NSTextView, palette: MarkdownEditorPalette, fontSize: CGFloat) {
        guard let textStorage = textView.textStorage else { return }
        let markdown = textView.string
        let ns = markdown as NSString
        let fullRange = NSRange(location: 0, length: ns.length)
        let selectedRange = textView.selectedRange()
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = 2
        paragraphStyle.paragraphSpacing = 4
        paragraphStyle.defaultTabInterval = 24

        let baseFont = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        let baseAttributes: [NSAttributedString.Key: Any] = [
            .font: baseFont,
            .foregroundColor: palette.foreground,
            .paragraphStyle: paragraphStyle
        ]

        textStorage.beginEditing()
        textStorage.setAttributes(baseAttributes, range: fullRange)

        applyLineHighlights(to: textStorage, markdown: markdown, palette: palette, fontSize: fontSize)
        applyInlineHighlights(to: textStorage, markdown: markdown, palette: palette, fontSize: fontSize)

        textStorage.endEditing()
        textView.typingAttributes = baseAttributes
        if selectedRange.location <= ns.length {
            textView.setSelectedRange(selectedRange)
        }
    }

    private static func applyLineHighlights(
        to textStorage: NSTextStorage,
        markdown: String,
        palette: MarkdownEditorPalette,
        fontSize: CGFloat
    ) {
        let ns = markdown as NSString
        var inFence = false
        for lineRange in markdownLineRanges(in: markdown) {
            let line = ns.substring(with: lineRange)
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)

            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                addAttributes(
                    [.foregroundColor: palette.code, .font: NSFont.monospacedSystemFont(ofSize: fontSize, weight: .semibold)],
                    to: textStorage,
                    range: lineRange
                )
                inFence.toggle()
                continue
            }

            if inFence {
                addAttributes(
                    [.foregroundColor: palette.code, .backgroundColor: palette.codeBackground],
                    to: textStorage,
                    range: lineRange
                )
                continue
            }

            if let heading = headingRangeAndLevel(in: line, lineRange: lineRange) {
                let size = fontSize + CGFloat(max(0, 7 - heading.level)) * 0.8
                addAttributes(
                    [
                        .foregroundColor: palette.heading,
                        .font: NSFont.monospacedSystemFont(ofSize: size, weight: .bold)
                    ],
                    to: textStorage,
                    range: heading.range
                )
                addAttributes([.foregroundColor: palette.marker], to: textStorage, range: heading.markerRange)
                continue
            }

            if trimmed.hasPrefix(">") {
                addAttributes(
                    [
                        .foregroundColor: palette.quote,
                        .font: NSFontManager.shared.convert(NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular), toHaveTrait: .italicFontMask)
                    ],
                    to: textStorage,
                    range: lineRange
                )
            }

            if trimmed.hasPrefix("---") || trimmed.hasPrefix("+++") {
                addAttributes([.foregroundColor: palette.frontMatter], to: textStorage, range: lineRange)
            }

            if let marker = listMarkerRange(in: line, lineRange: lineRange) {
                addAttributes([.foregroundColor: palette.marker], to: textStorage, range: marker)
            }
        }
    }

    private static func applyInlineHighlights(
        to textStorage: NSTextStorage,
        markdown: String,
        palette: MarkdownEditorPalette,
        fontSize: CGFloat
    ) {
        applyRegex(#"`[^`\n]+`"#, markdown: markdown, textStorage: textStorage) { range in
            [
                .foregroundColor: palette.code,
                .backgroundColor: palette.codeBackground,
                .font: NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
            ]
        }
        applyRegex(#"\*\*([^*\n]+)\*\*|__([^_\n]+)__"#, markdown: markdown, textStorage: textStorage) { _ in
            [
                .foregroundColor: palette.emphasis,
                .font: NSFont.monospacedSystemFont(ofSize: fontSize, weight: .bold)
            ]
        }
        applyRegex(#"(?<!\*)\*([^*\n]+)\*(?!\*)|_([^_\n]+)_"#, markdown: markdown, textStorage: textStorage) { _ in
            [
                .foregroundColor: palette.emphasis,
                .font: NSFontManager.shared.convert(NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular), toHaveTrait: .italicFontMask)
            ]
        }
        applyRegex(#"\[[^\]\n]+\]\([^)]+\)|\[\[[^\]\n]+\]\]"#, markdown: markdown, textStorage: textStorage) { _ in
            [
                .foregroundColor: palette.link,
                .underlineStyle: NSUnderlineStyle.single.rawValue
            ]
        }
    }

    private static func applyRegex(
        _ pattern: String,
        markdown: String,
        textStorage: NSTextStorage,
        attributes: (NSRange) -> [NSAttributedString.Key: Any]
    ) {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
        let range = NSRange(location: 0, length: (markdown as NSString).length)
        regex.enumerateMatches(in: markdown, range: range) { match, _, _ in
            guard let match else { return }
            addAttributes(attributes(match.range), to: textStorage, range: match.range)
        }
    }

    private static func headingRangeAndLevel(
        in line: String,
        lineRange: NSRange
    ) -> (range: NSRange, markerRange: NSRange, level: Int)? {
        let pattern = #"^(\s{0,3})(#{1,6})(\s+.+)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)),
              match.range(at: 2).location != NSNotFound else {
            return nil
        }
        let markerRange = NSRange(location: lineRange.location + match.range(at: 2).location, length: match.range(at: 2).length)
        let range = NSRange(location: lineRange.location + match.range.location, length: match.range.length)
        return (range, markerRange, match.range(at: 2).length)
    }

    private static func listMarkerRange(in line: String, lineRange: NSRange) -> NSRange? {
        let pattern = #"^\s*(?:[-*+]\s+(?:\[[ xX]\]\s+)?|\d+[.)]\s+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)) else {
            return nil
        }
        return NSRange(location: lineRange.location + match.range.location, length: match.range.length)
    }

    private static func addAttributes(
        _ attributes: [NSAttributedString.Key: Any],
        to textStorage: NSTextStorage,
        range: NSRange
    ) {
        guard range.location != NSNotFound,
              range.length > 0,
              range.location + range.length <= textStorage.length else {
            return
        }
        textStorage.addAttributes(attributes, range: range)
    }
}

func markdownLineRanges(in markdown: String) -> [NSRange] {
    let ns = markdown as NSString
    var ranges: [NSRange] = []
    var location = 0
    while location < ns.length {
        let range = ns.lineRange(for: NSRange(location: location, length: 0))
        ranges.append(range)
        location = range.location + max(range.length, 1)
    }
    if ns.length == 0 {
        ranges.append(NSRange(location: 0, length: 0))
    }
    return ranges
}
