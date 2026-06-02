import AppKit
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
                    drawsBackground: appearance.drawsContentBackground
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var filePathHeader: some View {
        PanelFilePathHeader(
            iconSystemName: panel.displayIcon ?? "doc.richtext",
            filePath: panel.filePath,
            foregroundColor: themeForegroundColor
        ) {
            if panel.displayMode == .text {
                PanelHeaderIconButton(
                    systemName: "arrow.counterclockwise",
                    label: String(localized: "markdown.toolbar.revert", defaultValue: "Revert"),
                    isDisabled: !panel.isDirty,
                    action: { panel.loadTextContent() }
                )

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
                .font(.system(size: 40))
                .foregroundColor(.secondary)
            Text(String(localized: "markdown.fileUnavailable.title", defaultValue: "File unavailable"))
                .font(.headline)
                .foregroundColor(.primary)
            Text(panel.filePath)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 24)
            Text(String(localized: "markdown.fileUnavailable.message", defaultValue: "The file may have been moved or deleted."))
                .font(.caption)
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

// MARK: - Toolbar

private struct MarkdownPanelToolbar: View {
    let confirmation: String?
    let onCopyMarkdown: () -> Void
    let onCopyHTML: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            if let confirmation {
                Text(confirmation)
                    .font(.system(size: 11, weight: .medium))
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

/// Header popover control for the markdown viewer's typography: a native font
/// picker, size field, max-width field, plus reset and set-as-default. Drives
/// the same `MarkdownPanel` model methods as the other markdown controls so
/// every entrypoint shares one path.
@MainActor
private struct MarkdownTypographyControl: View {
    @ObservedObject var panel: MarkdownPanel
    @State private var isPresented = false
    // Loaded lazily in the background after the popover appears so it opens
    // instantly even on machines with hundreds of fonts.
    @State private var families: [String] = []
    @State private var sizeText = ""
    @State private var maxWidthText = ""
    private let labelColumnWidth: CGFloat = 66

    private var buttonLabel: String {
        String(localized: "markdown.toolbar.fontSize", defaultValue: "Font Size")
    }

    private var sizeBinding: Binding<Double> {
        Binding(get: { panel.fontSize }, set: { _ = panel.setFontSize($0) })
    }

    private var fontBinding: Binding<String> {
        Binding(get: { panel.fontFamily }, set: { _ = panel.setFontFamily($0) })
    }

    private var maxWidthBinding: Binding<Double> {
        Binding(get: { panel.maxContentWidth }, set: { _ = panel.setMaxContentWidth($0) })
    }

    /// The current selection is always tag-able, even before the full list loads.
    private var pickerFamilies: [String] {
        let current = panel.fontFamily
        if !current.isEmpty, !families.contains(current) {
            return [current] + families
        }
        return families
    }

    var body: some View {
        Button { isPresented.toggle() } label: {
            PanelHeaderIconGlyph(systemName: "textformat.size")
        }
        .buttonStyle(.plain)
        .foregroundColor(.secondary)
        .help(buttonLabel)
        .accessibilityLabel(buttonLabel)
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            popoverContent
        }
    }

    private var popoverContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 14) {
                    fieldLabel(String(localized: "markdown.typography.font", defaultValue: "Font"))
                    fontPicker
                }
                HStack(alignment: .firstTextBaseline, spacing: 14) {
                    fieldLabel(String(localized: "markdown.typography.size", defaultValue: "Size"))
                    HStack(spacing: 6) {
                        TextField(
                            String(localized: "markdown.fontSize.field", defaultValue: "Size"),
                            text: $sizeText
                        )
                        .labelsHidden()
                        .frame(width: 44)
                        .multilineTextAlignment(.trailing)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: sizeText) {
                            applySizeTextIfValid()
                        }
                        .onSubmit {
                            commitSizeText()
                        }
                        Text(String(localized: "markdown.fontSize.unit", defaultValue: "pt"))
                            .foregroundStyle(.secondary)
                        Stepper(
                            "",
                            value: sizeBinding,
                            in: MarkdownFontSizeSettings.minimumPointSize...MarkdownFontSizeSettings.maximumPointSize,
                            step: MarkdownFontSizeSettings.stepPointSize
                        )
                        .labelsHidden()
                    }
                }
                HStack(alignment: .firstTextBaseline, spacing: 14) {
                    fieldLabel(String(localized: "markdown.typography.maxWidth", defaultValue: "Max Width"))
                    HStack(spacing: 6) {
                        TextField(
                            String(localized: "markdown.maxWidth.field", defaultValue: "Width"),
                            text: $maxWidthText
                        )
                        .labelsHidden()
                        .frame(width: 54)
                        .multilineTextAlignment(.trailing)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: maxWidthText) {
                            applyMaxWidthTextIfValid()
                        }
                        .onSubmit {
                            commitMaxWidthText()
                        }
                        Text(String(localized: "markdown.maxWidth.unit", defaultValue: "px"))
                            .foregroundStyle(.secondary)
                        Stepper(
                            "",
                            value: maxWidthBinding,
                            in: MarkdownMaxWidthSettings.minimumCSSPixels...MarkdownMaxWidthSettings.maximumCSSPixels,
                            step: MarkdownMaxWidthSettings.stepCSSPixels
                        )
                        .labelsHidden()
                    }
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Button(String(localized: "markdown.fontSize.reset", defaultValue: "Reset to default")) {
                    panel.resetTypography()
                }
                Button(String(localized: "markdown.typography.resetBuiltIn", defaultValue: "Reset to built-in defaults")) {
                    panel.resetTypographyToBuiltInDefaults()
                }
                Button(String(localized: "markdown.fontSize.setDefault", defaultValue: "Set as default for new viewers")) {
                    MarkdownTypographyDefaults.setDefault(
                        fontSize: panel.fontSize,
                        fontFamily: panel.fontFamily,
                        maxContentWidth: panel.maxContentWidth
                    )
                }
            }
            .buttonStyle(.link)
        }
        .padding(14)
        .frame(width: 272)
        .onAppear {
            syncDraftFieldsFromPanel()
        }
        .onChange(of: isPresented) { _, presented in
            if presented {
                syncDraftFieldsFromPanel()
            }
        }
        .onChange(of: panel.fontSize) {
            syncSizeTextFromPanel()
        }
        .onChange(of: panel.maxContentWidth) {
            syncMaxWidthTextFromPanel()
        }
        .task {
            // Load the installed font list off-main after the popover is shown.
            if families.isEmpty {
                families = await MarkdownFontFamily.availableFamilies()
            }
        }
    }

    private func fieldLabel(_ title: String) -> some View {
        Text(title)
            .foregroundStyle(.secondary)
            .frame(width: labelColumnWidth, alignment: .leading)
    }

    private func syncDraftFieldsFromPanel() {
        syncSizeTextFromPanel()
        syncMaxWidthTextFromPanel()
    }

    private func syncSizeTextFromPanel() {
        let next = integerText(panel.fontSize)
        if sizeText != next {
            sizeText = next
        }
    }

    private func syncMaxWidthTextFromPanel() {
        let next = integerText(panel.maxContentWidth)
        if maxWidthText != next {
            maxWidthText = next
        }
    }

    private func applySizeTextIfValid() {
        guard let value = Double(sizeText.trimmingCharacters(in: .whitespacesAndNewlines)),
              value >= MarkdownFontSizeSettings.minimumPointSize,
              value <= MarkdownFontSizeSettings.maximumPointSize else { return }
        _ = panel.setFontSize(value)
    }

    private func applyMaxWidthTextIfValid() {
        guard let value = Double(maxWidthText.trimmingCharacters(in: .whitespacesAndNewlines)),
              value >= MarkdownMaxWidthSettings.minimumCSSPixels,
              value <= MarkdownMaxWidthSettings.maximumCSSPixels else { return }
        _ = panel.setMaxContentWidth(value)
    }

    private func commitSizeText() {
        guard let value = Double(sizeText.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            syncSizeTextFromPanel()
            return
        }
        _ = panel.setFontSize(value)
        syncSizeTextFromPanel()
    }

    private func commitMaxWidthText() {
        guard let value = Double(maxWidthText.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            syncMaxWidthTextFromPanel()
            return
        }
        _ = panel.setMaxContentWidth(value)
        syncMaxWidthTextFromPanel()
    }

    private func integerText(_ value: Double) -> String {
        String(Int(value.rounded()))
    }

    private var fontPicker: some View {
        // Plain system-font names: rendering each item in its own font made the
        // menu slow to open and gave rows uneven heights. The chosen font still
        // applies to the document.
        Picker(selection: fontBinding) {
            Text(String(localized: "markdown.font.system", defaultValue: "System"))
                .tag(MarkdownFontFamily.systemDefault)
            Divider()
            ForEach(pickerFamilies, id: \.self) { family in
                Text(family).tag(family)
            }
        } label: { EmptyView() }
        .labelsHidden()
        .pickerStyle(.menu)
        .frame(width: 150, alignment: .leading)
    }
}
