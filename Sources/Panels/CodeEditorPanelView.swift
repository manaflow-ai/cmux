import SwiftUI
import AppKit
import Neon
import SwiftTreeSitter

struct CodeEditorPanelView: View {
    @ObservedObject var panel: CodeEditorPanel
    let isFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            // Header bar
            HStack(spacing: 6) {
                Image(systemName: "doc.text")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                Text(panel.displayTitle)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                if panel.isDirty {
                    Circle()
                        .fill(Color.primary.opacity(0.5))
                        .frame(width: 6, height: 6)
                }
                if let lang = panel.detectedLanguageName {
                    Text(lang)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.12))
                        .cornerRadius(4)
                }
                Spacer()
                Text(panel.filePath)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color(nsColor: .controlBackgroundColor))

            Divider()

            // Editor
            CodeEditorTextView(
                initialText: panel.initialContent,
                filePath: panel.filePath,
                onFirstAppear: { textView in
                    panel.currentTextProvider = { [weak textView] in
                        textView?.string ?? ""
                    }
                },
                onTextChange: {
                    if !panel.isDirty { panel.isDirty = true }
                },
                onSave: { panel.save() }
            )
        }
    }
}

// MARK: - NSTextView wrapper

struct CodeEditorTextView: NSViewRepresentable {
    let initialText: String
    let filePath: String
    var onFirstAppear: (NSTextView) -> Void
    var onTextChange: () -> Void
    var onSave: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onTextChange: onTextChange)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder

        let textView = SaveAwareTextView()
        textView.isEditable = true
        textView.isSelectable = true
        textView.allowsUndo = true
        textView.isRichText = true
        textView.usesFontPanel = false
        let config = GhosttyConfig.load()
        let baseFont = NSFont.monospacedSystemFont(ofSize: config.fontSize, weight: .regular)
        textView.font = baseFont
        textView.textColor = config.foregroundColor
        textView.backgroundColor = config.backgroundColor
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.insertionPointColor = config.cursorColor

        // Line wrapping
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.autoresizingMask = [.width]

        // Insets
        textView.textContainerInset = NSSize(width: 8, height: 8)

        textView.string = initialText
        textView.typingAttributes = [
            .font: baseFont,
            .foregroundColor: config.foregroundColor,
        ]
        textView.delegate = context.coordinator
        textView.onSave = onSave

        scrollView.documentView = textView

        // Give the panel access to the text view's current content
        onFirstAppear(textView)

        // Set up syntax highlighting — parse config off-main, apply on main
        let coordinator = context.coordinator
        let path = filePath
        DispatchQueue.global(qos: .userInitiated).async {
            guard let langConfig = LanguageDetection.languageConfiguration(forFilePath: path) else { return }
            let provider = SyntaxHighlightTheme.attributeProvider(baseFont: baseFont)
            DispatchQueue.main.async {
                let config = TextViewHighlighter.Configuration(
                    languageConfiguration: langConfig,
                    attributeProvider: provider,
                    locationTransformer: { _ in nil }
                )
                guard let highlighter = try? TextViewHighlighter(textView: textView, configuration: config) else { return }
                highlighter.observeEnclosingScrollView()
                coordinator.highlighter = highlighter
            }
        }

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        // NSTextView is the source of truth — no updates needed from SwiftUI
    }

    class Coordinator: NSObject, NSTextViewDelegate {
        let onTextChange: () -> Void
        var highlighter: TextViewHighlighter?

        init(onTextChange: @escaping () -> Void) {
            self.onTextChange = onTextChange
        }

        func textDidChange(_ notification: Notification) {
            onTextChange()
        }
    }
}

// MARK: - NSTextView subclass for Cmd+S and plain-text paste

private class SaveAwareTextView: NSTextView {
    var onSave: (() -> Void)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == .command && event.charactersIgnoringModifiers == "s" {
            onSave?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func paste(_ sender: Any?) {
        pasteAsPlainText(sender)
    }
}
