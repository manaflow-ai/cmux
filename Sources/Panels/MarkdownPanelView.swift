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
                onRequestPanelFocus: onRequestPanelFocus,
                onCancelFind: { [weak panel] in panel?.setPreviewFindVisible(false) }
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
                    wordWrap: fileEditorWordWrap
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
