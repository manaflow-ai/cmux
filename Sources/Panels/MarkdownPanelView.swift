import AppKit
import CmuxFoundation
import SwiftUI
import WebKit

/// SwiftUI view that renders a MarkdownPanel's content in a WKWebView using
/// marked.js + github-markdown-css + highlight.js.
///
/// We render through a web view (rather than the previous MarkdownUI path)
/// so that:
///   - Native browser text selection works across the entire document
///     (Cmd+A / drag-select span paragraphs, headings, code blocks, etc.).
///     MarkdownUI rendered each block as an isolated SwiftUI `Text`, which
///     made it impossible to select more than one block at a time.
///   - Rendering uses GitHub's actual markdown CSS, so tables, task lists,
///     nested lists, blockquotes, and code blocks look identical to what
///     users see on github.com.
///   - We can copy the rendered HTML straight from the same source the user
///     is reading.
struct MarkdownPanelView: View {
    @ObservedObject var panel: MarkdownPanel
    let isFocused: Bool
    let isVisibleInUI: Bool
    let portalPriority: Int
    let appearance: PanelAppearance
    let onRequestPanelFocus: () -> Void

    @State private var focusFlashOpacity: Double = 0.0
    @State private var focusFlashAnimationGeneration: Int = 0
    @State private var copyConfirmation: CopyConfirmation? = nil
    @State private var copyConfirmationGeneration: Int = 0
    @AppStorage(FilePreviewWordWrapSettings.key) private var fileEditorWordWrap = FilePreviewWordWrapSettings.defaultEnabled

    private enum CopyConfirmation: Equatable {
        case markdown
        case html

        var label: String {
            switch self {
            case .markdown:
                return String(localized: "markdown.copyConfirm.markdown", defaultValue: "Copied as Markdown")
            case .html:
                return String(localized: "markdown.copyConfirm.html", defaultValue: "Copied as HTML")
            }
        }
    }

    var body: some View {
        Group {
            if panel.isFileUnavailable {
                fileUnavailableView
            } else {
                markdownContentView
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(contentBackgroundColor)
        .overlay {
            WorkspaceAttentionFlashRingView(opacity: focusFlashOpacity)
        }
        .onChange(of: panel.focusFlashToken) {
            triggerFocusFlashAnimation()
        }
        .environment(\.colorScheme, themeColorScheme)
    }

    // MARK: - Content

    private var markdownContentView: some View {
        VStack(alignment: .leading, spacing: 0) {
            filePathHeader

            Divider()

            markdownBody
        }
    }

    @ViewBuilder
    private var markdownBody: some View {
        ZStack {
            MarkdownWebRenderer(
                markdown: panel.content,
                theme: MarkdownWebTheme.resolve(backgroundColor: themeBackgroundColor),
                backgroundColor: appearance.contentBackgroundColor,
                panelId: panel.id,
                workspaceId: panel.workspaceId,
                filePath: panel.filePath,
                fontSize: panel.fontSize,
                fontFamily: panel.fontFamily,
                maxContentWidth: panel.maxContentWidth,
                session: panel.rendererSession,
                onRequestPanelFocus: onRequestPanelFocus
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .opacity(panel.displayMode == .preview ? 1 : 0)
            .allowsHitTesting(panel.displayMode == .preview)
            .accessibilityHidden(panel.displayMode != .preview)

            if panel.displayMode == .text {
                FilePreviewTextEditor(
                    panel: panel,
                    isVisibleInUI: isVisibleInUI,
                    themeBackgroundColor: appearance.contentBackgroundColor,
                    themeForegroundColor: themeForegroundColor,
                    drawsBackground: appearance.drawsContentBackground,
                    wordWrap: fileEditorWordWrap,
                    onPointerDown: onRequestPanelFocus
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    @ViewBuilder
    private var filePathHeader: some View {
        if panel.isProjectNote {
            // Project notes live at store-managed paths, so the header leads
            // with the record title as a Google-Docs-style rename field
            // instead of the meaningless file path (still available via the
            // field's tooltip and the external-open menu).
            HStack(spacing: 8) {
                NoteTitleRenameField(
                    title: panel.displayTitle,
                    filePath: panel.filePath,
                    foregroundColor: themeForegroundColor,
                    onRename: { panel.renameNoteTitle($0) }
                )
                Spacer(minLength: 8)
                headerTrailingControls
            }
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background(Color.clear)
        } else {
            PanelFilePathHeader(
                iconSystemName: nil,
                filePath: panel.filePath,
                foregroundColor: themeForegroundColor
            ) {
                headerTrailingControls
            }
        }
    }

    @ViewBuilder
    private var headerTrailingControls: some View {
        // Notes auto-save, so the Save control only appears for plain
        // Markdown files (which still save explicitly).
        if panel.displayMode == .text, !panel.behavesAsNote, panel.isDirty || panel.isSaving {
            PanelHeaderIconButton(
                systemName: "square.and.arrow.down",
                label: String(localized: "markdown.toolbar.save", defaultValue: "Save"),
                isDisabled: !panel.isDirty || panel.isSaving,
                action: { panel.saveTextContent() }
            )
        }
        if panel.displayMode == .preview {
            MarkdownTypographyControl(panel: panel)
        }
        markdownModeButton
        MarkdownPanelToolbar(
            confirmation: copyConfirmation?.label,
            onCopyMarkdown: { copyAsMarkdown() },
            onCopyHTML: { copyAsHTML() }
        )
        FileExternalOpenMenu(
            fileURL: URL(fileURLWithPath: panel.filePath),
            isDisabled: panel.isFileUnavailable
        )
    }

    // MARK: - Copy actions

    private func copyAsMarkdown() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(panel.content, forType: .string)
        flashCopyConfirmation(.markdown)
    }

    private func copyAsHTML() {
        Task { @MainActor in
            guard let html = await panel.rendererSession.renderedHTML(markdown: panel.content) else { return }
            // Plain-text targets get readable text, not raw markup.
            let text = await panel.rendererSession.renderedText() ?? panel.content
            let pb = NSPasteboard.general
            pb.clearContents()
            // public.html for rich-text-aware targets (Notes, Mail, Pages, ...)
            // and a plain-text fallback so plain editors still receive content.
            pb.setString(html, forType: .html)
            pb.setString(text, forType: .string)
            flashCopyConfirmation(.html)
        }
    }

    private func flashCopyConfirmation(_ kind: CopyConfirmation) {
        copyConfirmationGeneration &+= 1
        let generation = copyConfirmationGeneration
        copyConfirmation = kind
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            guard copyConfirmationGeneration == generation else { return }
            if copyConfirmation == kind {
                copyConfirmation = nil
            }
        }
    }

    private var markdownModeButton: some View {
        switch panel.displayMode {
        case .preview:
            PanelHeaderIconButton(
                systemName: "doc.plaintext",
                label: String(localized: "markdown.mode.showTextEdit", defaultValue: "Show TextEdit"),
                action: { panel.setDisplayMode(.text) }
            )
        case .text:
            PanelHeaderIconButton(
                systemName: "eye",
                label: String(localized: "markdown.mode.showPreview", defaultValue: "Show Preview"),
                action: { panel.setDisplayMode(.preview) }
            )
        }
    }

    private var fileUnavailableView: some View {
        VStack(spacing: 12) {
            Image(systemName: "doc.questionmark")
                .cmuxFont(size: 40)
                .foregroundColor(.secondary)
            Text(String(localized: "markdown.fileUnavailable.title", defaultValue: "File unavailable"))
                .cmuxFont(.headline)
                .foregroundColor(.primary)
            Text(panel.filePath)
                .cmuxFont(size: 12, design: .monospaced)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 24)
            Text(String(localized: "markdown.fileUnavailable.message", defaultValue: "The file may have been moved or deleted."))
                .cmuxFont(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Theme

    private var contentBackgroundColor: Color {
        Color(nsColor: appearance.contentBackgroundColor)
    }

    private var themeBackgroundColor: NSColor {
        appearance.backgroundColor
    }

    private var themeForegroundColor: NSColor {
        appearance.foregroundColor
    }

    private var themeColorScheme: ColorScheme {
        themeBackgroundColor.isLightColor ? .light : .dark
    }

    // MARK: - Focus Flash

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

/// Google-Docs-style inline rename for a note's title: reads as plain header
/// text, grows a subtle outline on hover, and edits in place on click.
/// Enter or clicking away commits through `onRename`; Escape restores the
/// committed title. The committed title stays authoritative — external
/// retitles (tree rename, another panel) overwrite an idle field but never
/// an in-progress edit.
private struct NoteTitleRenameField: View {
    let title: String
    let filePath: String
    let foregroundColor: NSColor
    let onRename: (String) -> Void

    @State private var draft: String = ""
    @State private var isHovering = false
    @State private var isFocused = false

    private var placeholder: String {
        String(localized: "note.title.placeholder", defaultValue: "Untitled note")
    }

    private var titleFont: Font {
        .system(size: 12, weight: .semibold)
    }

    private var titleNSFont: NSFont {
        .systemFont(ofSize: 12, weight: .semibold)
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "doc.text")
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(Color(nsColor: foregroundColor).opacity(0.58))
                .frame(width: 16, height: 20)

            // Size the editable field from label text so the title behaves like
            // the other compact panel headers while still accepting in-place edits.
            Text(draft.isEmpty ? placeholder : draft)
                .font(titleFont)
                .lineLimit(1)
                .truncationMode(.tail)
                .opacity(0)
                .accessibilityHidden(true)
                .overlay(alignment: .leading) {
                    NoteTitleTextFieldRepresentable(
                        placeholder: placeholder,
                        text: $draft,
                        isFocused: $isFocused,
                        font: titleNSFont,
                        foregroundColor: foregroundColor,
                        onCommit: commit,
                        onCancel: { draft = title }
                    )
                }
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(isFocused ? Color.accentColor.opacity(0.65) : Color(nsColor: foregroundColor).opacity(0.22))
                        .frame(height: 1)
                        .opacity(isFocused || isHovering ? 1 : 0)
                }
                .frame(minWidth: 40, minHeight: 20, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .layoutPriority(1)
            .onHover { isHovering = $0 }
            .onAppear { draft = title }
            .onChange(of: title) { _, newValue in
                guard !isFocused else { return }
                draft = newValue
            }
            .help(filePath)
            .accessibilityLabel(String(localized: "note.title.accessibility", defaultValue: "Note title"))
    }

    private func commit() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != title else {
            draft = title
            return
        }
        onRename(trimmed)
    }
}

private final class NoteTitleNativeTextField: NSTextField {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = false
        isBezeled = false
        drawsBackground = false
        focusRingType = .none
        usesSingleLineMode = true
        lineBreakMode = .byTruncatingTail
        cell?.wraps = false
        cell?.truncatesLastVisibleLine = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .iBeam)
    }
}

private struct NoteTitleTextFieldRepresentable: NSViewRepresentable {
    let placeholder: String
    @Binding var text: String
    @Binding var isFocused: Bool
    let font: NSFont
    let foregroundColor: NSColor
    let onCommit: () -> Void
    let onCancel: () -> Void

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: NoteTitleTextFieldRepresentable
        var isProgrammaticMutation = false
        var skipCommitOnEndEditing = false

        init(parent: NoteTitleTextFieldRepresentable) {
            self.parent = parent
        }

        func controlTextDidChange(_ obj: Notification) {
            guard !isProgrammaticMutation else { return }
            guard let field = obj.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func controlTextDidBeginEditing(_ obj: Notification) {
            if !parent.isFocused {
                parent.isFocused = true
            }
        }

        func controlTextDidEndEditing(_ obj: Notification) {
            if parent.isFocused {
                parent.isFocused = false
            }
            if skipCommitOnEndEditing {
                skipCommitOnEndEditing = false
                return
            }
            parent.onCommit()
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard !textView.hasMarkedText() else { return false }
            switch commandSelector {
            case #selector(NSResponder.insertNewline(_:)):
                textView.window?.makeFirstResponder(nil)
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                skipCommitOnEndEditing = true
                parent.onCancel()
                textView.window?.makeFirstResponder(nil)
                return true
            default:
                return false
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NoteTitleNativeTextField {
        let field = NoteTitleNativeTextField(frame: .zero)
        field.delegate = context.coordinator
        field.isEditable = true
        field.isSelectable = true
        field.isEnabled = true
        applyStyle(to: field)
        field.stringValue = text
        return field
    }

    func updateNSView(_ field: NoteTitleNativeTextField, context: Context) {
        context.coordinator.parent = self
        applyStyle(to: field)
        if field.currentEditor() == nil, field.stringValue != text {
            context.coordinator.isProgrammaticMutation = true
            field.stringValue = text
            context.coordinator.isProgrammaticMutation = false
        }
    }

    static func dismantleNSView(_ field: NoteTitleNativeTextField, coordinator: Coordinator) {
        field.delegate = nil
    }

    private func applyStyle(to field: NoteTitleNativeTextField) {
        field.font = font
        field.textColor = foregroundColor.withAlphaComponent(0.88)
        field.placeholderAttributedString = NSAttributedString(
            string: placeholder,
            attributes: [
                .font: font,
                .foregroundColor: foregroundColor.withAlphaComponent(0.42)
            ]
        )
    }
}

private struct MarkdownPanelToolbar: View {
    let confirmation: String?
    let onCopyMarkdown: () -> Void
    let onCopyHTML: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            if let confirmation {
                Text(confirmation)
                    .cmuxFont(size: 11, weight: .medium)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .transition(.opacity)
            }

            toolbarButton(
                title: String(localized: "markdown.toolbar.copyMarkdown", defaultValue: "Copy as Markdown"),
                systemImage: "doc.on.doc",
                action: onCopyMarkdown
            )
            toolbarButton(
                title: String(localized: "markdown.toolbar.copyHTML", defaultValue: "Copy as HTML"),
                systemImage: "chevron.left.forwardslash.chevron.right",
                action: onCopyHTML
            )
        }
        .animation(.easeOut(duration: 0.15), value: confirmation)
    }

    private func toolbarButton(title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        PanelHeaderIconButton(
            systemName: systemImage,
            label: title,
            action: action
        )
    }
}
