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
    @AppStorage(FilePreviewWordWrapSettings.key) private var fileEditorWordWrap = FilePreviewWordWrapSettings.defaultEnabled

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

    private var filePathHeader: some View {
        PanelFilePathHeader(
            iconSystemName: nil,
            filePath: panel.filePath,
            foregroundColor: themeForegroundColor
        ) {
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
            moreActionsMenu
        }
    }

    /// Viewer utilities shared by notes and plain markdown: copy the source
    /// markdown, copy the rendered HTML (the same DOM the user is reading),
    /// and hand the file to the system (default app / Finder).
    private var moreActionsMenu: some View {
        Menu {
            Button(String(localized: "markdown.toolbar.copyMarkdown", defaultValue: "Copy as Markdown")) {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(panel.content, forType: .string)
            }
            Button(String(localized: "markdown.toolbar.copyHTML", defaultValue: "Copy as HTML")) {
                Task { @MainActor in
                    guard let html = await panel.rendererSession.renderedHTML() else { return }
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.declareTypes([.html, .string], owner: nil)
                    pasteboard.setString(html, forType: .html)
                    pasteboard.setString(html, forType: .string)
                }
            }
            Divider()
            Button(FileExternalOpenText.openExternally) {
                NSWorkspace.shared.open(URL(fileURLWithPath: panel.filePath))
            }
            Button(FileExternalOpenText.revealInFinder) {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: panel.filePath)])
            }
        } label: {
            PanelHeaderIconGlyph(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .foregroundColor(.secondary)
        .help(String(localized: "markdown.toolbar.more", defaultValue: "More Actions"))
        .accessibilityLabel(String(localized: "markdown.toolbar.more", defaultValue: "More Actions"))
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

