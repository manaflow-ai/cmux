import SwiftUI
import AppKit
import STTextView
import STPluginNeon
import TextFormation
import TextFormationPlugin

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
                        textView?.text ?? ""
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

// MARK: - STTextView wrapper

struct CodeEditorTextView: NSViewRepresentable {
    let initialText: String
    let filePath: String
    var onFirstAppear: (STTextView) -> Void
    var onTextChange: () -> Void
    var onSave: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onTextChange: onTextChange, onSave: onSave)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let config = GhosttyConfig.load()
        let baseFont = NSFont.monospacedSystemFont(ofSize: config.fontSize, weight: .regular)

        let textView = SaveAwareSTTextView()
        textView.font = baseFont
        textView.textColor = config.foregroundColor
        textView.backgroundColor = config.backgroundColor
        textView.insertionPointColor = config.cursorColor
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.usesFontPanel = false

        // Line wrapping
        textView.isHorizontallyResizable = false

        // Line numbers
        textView.showsLineNumbers = true
        if let gutter = textView.gutterView {
            gutter.textColor = config.foregroundColor.withAlphaComponent(0.35)
            gutter.drawSeparator = true
            gutter.separatorColor = config.foregroundColor.withAlphaComponent(0.12)
        }

        // Current line highlight
        textView.highlightSelectedLine = true
        textView.selectedLineHighlightColor = config.backgroundColor.isLightColor
            ? NSColor.black.withAlphaComponent(0.04)
            : NSColor.white.withAlphaComponent(0.04)

        // Tab width
        let paragraph = NSParagraphStyle.default.mutableCopy() as! NSMutableParagraphStyle
        let charWidth = ("0" as NSString).size(withAttributes: [.font: baseFont]).width
        paragraph.defaultTabInterval = CGFloat(config.tabWidth) * charWidth
        textView.defaultParagraphStyle = paragraph

        // Set initial text
        textView.text = initialText

        // Syntax highlighting via Plugin-Neon
        if let lang = LanguageDetection.treeSitterLanguage(forFilePath: filePath) {
            let theme = SyntaxHighlightTheme.neonTheme(baseFont: baseFont)
            textView.addPlugin(NeonPlugin(theme: theme, language: lang))
        }

        // Auto-indentation and bracket handling via TextFormation
        let indentUnit = String(repeating: " ", count: config.tabWidth)
        let indenter = TextualIndenter(patterns: TextualIndenter.basicPatterns)
        let filters: [Filter] = [
            StandardOpenPairFilter(open: "(", close: ")"),
            StandardOpenPairFilter(open: "{", close: "}"),
            StandardOpenPairFilter(open: "[", close: "]"),
            StandardOpenPairFilter(same: "\""),
            StandardOpenPairFilter(same: "'"),
            StandardOpenPairFilter(same: "`"),
            NewlineProcessingFilter(),
        ]
        let providers = WhitespaceProviders(
            leadingWhitespace: indenter.substitionProvider(indentationUnit: indentUnit, width: config.tabWidth),
            trailingWhitespace: WhitespaceProviders.removeAllProvider
        )
        textView.addPlugin(TextFormationPlugin(filters: filters, whitespaceProviders: providers))

        // Delegate and save handler
        textView.textDelegate = context.coordinator
        textView.onSave = onSave

        // Scroll view
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.documentView = textView

        // Give the panel access to the text view's current content
        onFirstAppear(textView)

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        // STTextView is the source of truth — no updates needed from SwiftUI
    }

    class Coordinator: NSObject, STTextViewDelegate {
        let onTextChange: () -> Void
        let onSave: () -> Void

        init(onTextChange: @escaping () -> Void, onSave: @escaping () -> Void) {
            self.onTextChange = onTextChange
            self.onSave = onSave
        }

        func textViewDidChangeText(_ notification: Notification) {
            onTextChange()
        }
    }
}

// MARK: - STTextView subclass for Cmd+S

private class SaveAwareSTTextView: STTextView {
    var onSave: (() -> Void)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == .command && event.charactersIgnoringModifiers == "s" {
            onSave?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}
