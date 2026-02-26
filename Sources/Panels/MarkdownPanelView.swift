import SwiftUI
import AppKit
import WebKit

enum MarkdownPreviewRenderer {
    static let lightCSSURL = "https://cdn.jsdelivr.net/npm/github-markdown-css@5.8.1/github-markdown.min.css"
    static let darkCSSURL = "https://cdn.jsdelivr.net/npm/github-markdown-css@5.8.1/github-markdown-dark.min.css"

    static func renderedHTML(markdown: String, isDarkMode: Bool) -> String {
        let markdownBase64 = Data(markdown.utf8).base64EncodedString()
        let cssURL = isDarkMode ? darkCSSURL : lightCSSURL
        let pageBackground = isDarkMode ? "#0d1117" : "#ffffff"
        let tableRowBg = isDarkMode ? "#0d1117" : "#ffffff"
        let tableAltRowBg = isDarkMode ? "#151b23" : "#f6f8fa"
        let tableBorder = isDarkMode ? "#3d444d" : "#d1d9e0"
        let tableText = isDarkMode ? "#f0f6fc" : "#1f2328"
        let inlineCodeBg = isDarkMode ? "#656c7633" : "#afb8c133"

        return """
        <html>
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <link rel="stylesheet" href="\(cssURL)">
          <style>
            html, body {
              margin: 0;
              padding: 0;
              background: \(pageBackground);
            }
            .canvas {
              padding: 16px 20px 22px 20px;
              background: \(pageBackground);
              box-sizing: border-box;
            }
            .markdown-body {
              box-sizing: border-box;
              min-width: 200px;
              max-width: 980px;
              margin: 0 auto;
            }
            .fallback {
              white-space: pre-wrap;
              font-family: ui-monospace, SFMono-Regular, Menlo, Monaco, monospace;
              font-size: 12px;
            }
            /* Explicit overrides to keep table/code colors aligned with GitHub tokens */
            .markdown-body { color: \(tableText); }
            .markdown-body table tr {
              background-color: \(tableRowBg);
              border-top: 1px solid \(tableBorder);
            }
            .markdown-body table tr:nth-child(2n) { background-color: \(tableAltRowBg); }
            .markdown-body table th, .markdown-body table td {
              color: \(tableText);
              border: 1px solid \(tableBorder);
            }
            .markdown-body code, .markdown-body tt {
              color: \(tableText);
              background-color: \(inlineCodeBg);
            }
            @media (prefers-color-scheme: dark) {
              .fallback {
                color: #f0f6fc;
              }
            }
          </style>
          <script src="https://cdn.jsdelivr.net/npm/marked/marked.min.js"></script>
        </head>
        <body>
          <div class="canvas">
            <article id="content" class="markdown-body"></article>
          </div>
          <script>
            function decodeBase64Utf8(b64) {
              const binary = atob(b64);
              const bytes = new Uint8Array(binary.length);
              for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
              return new TextDecoder('utf-8').decode(bytes);
            }

            function render() {
              const host = document.getElementById('content');
              const raw = decodeBase64Utf8('\(markdownBase64)');
              if (window.marked && typeof window.marked.parse === 'function') {
                marked.setOptions({ gfm: true, breaks: false, mangle: false, headerIds: false });
                host.innerHTML = marked.parse(raw);
              } else {
                host.classList.add('fallback');
                host.textContent = raw;
              }
            }

            try { render(); } catch (e) {
              const host = document.getElementById('content');
              host.classList.add('fallback');
              host.textContent = decodeBase64Utf8('\(markdownBase64)');
            }
          </script>
        </body>
        </html>
        """
    }
}

private struct MarkdownPreviewTextView: NSViewRepresentable {
    let markdown: String

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.preferredContentMode = .desktop
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.loadHTMLString(
            MarkdownPreviewRenderer.renderedHTML(markdown: markdown, isDarkMode: resolvedIsDarkMode()),
            baseURL: nil
        )
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        nsView.loadHTMLString(
            MarkdownPreviewRenderer.renderedHTML(markdown: markdown, isDarkMode: resolvedIsDarkMode()),
            baseURL: nil
        )
    }

    private func resolvedIsDarkMode() -> Bool {
        NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

}

private struct MarkdownEditorTextView: NSViewRepresentable {
    @Binding var text: String
    private let highlighter = MarkdownEditorHighlighter()

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true

        let textView = NSTextView(frame: .zero)
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.backgroundColor = .textBackgroundColor
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.string = text
        highlighter.apply(to: textView)

        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? NSTextView else { return }
        if textView.string != text {
            context.coordinator.isProgrammaticUpdate = true
            textView.string = text
            highlighter.apply(to: textView)
            context.coordinator.isProgrammaticUpdate = false
        } else {
            highlighter.apply(to: textView)
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MarkdownEditorTextView
        var isProgrammaticUpdate = false

        init(parent: MarkdownEditorTextView) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard !isProgrammaticUpdate,
                  let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
            parent.highlighter.apply(to: textView)
        }
    }
}

enum MarkdownEditorThemePalette {
    struct TokenHexes: Equatable {
        let heading: String
        let mutedAccent: String
        let emphasis: String
        let link: String
        let code: String
        let codeBackground: String
        let htmlTag: String
        let htmlAttributeName: String
        let htmlAttributeValue: String
        let htmlComment: String
    }

    static func tokenHexes(isDarkMode: Bool) -> TokenHexes {
        if isDarkMode {
            // VS Code Dark+ inspired token colors (widely used default dark editor scheme).
            return TokenHexes(
                heading: "#569CD6",
                mutedAccent: "#9CDCFE",
                emphasis: "#C586C0",
                link: "#569CD6",
                code: "#CE9178",
                codeBackground: "#2D2D2D",
                htmlTag: "#569CD6",
                htmlAttributeName: "#9CDCFE",
                htmlAttributeValue: "#CE9178",
                htmlComment: "#6A9955"
            )
        }
        // VS Code Light+ inspired token colors (widely used default light editor scheme).
        return TokenHexes(
            heading: "#0000FF",
            mutedAccent: "#001080",
            emphasis: "#AF00DB",
            link: "#0451A5",
            code: "#A31515",
            codeBackground: "#F3F3F3",
            htmlTag: "#800000",
            htmlAttributeName: "#FF0000",
            htmlAttributeValue: "#0451A5",
            htmlComment: "#008000"
        )
    }
}

private struct MarkdownEditorHighlighter {
    private let baseFont = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
    private let strongFont = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
    private let headingRegex = try? NSRegularExpression(pattern: "(?m)^#{1,6}\\s+.*$")
    private let quoteRegex = try? NSRegularExpression(pattern: "(?m)^\\s{0,3}>\\s?.*$")
    private let listMarkerRegex = try? NSRegularExpression(pattern: "(?m)^\\s{0,3}(?:[-+*]|\\d+\\.)\\s+")
    private let strongRegex = try? NSRegularExpression(pattern: "\\*\\*[^*\\n]+\\*\\*|__[^_\\n]+__")
    private let emphasisRegex = try? NSRegularExpression(pattern: "(?<!\\*)\\*[^*\\n]+\\*(?!\\*)|(?<!_)_[^_\\n]+_(?!_)")
    private let linkRegex = try? NSRegularExpression(pattern: "\\[[^\\]]+\\]\\([^\\)]+\\)")
    private let htmlCommentRegex = try? NSRegularExpression(pattern: "<!--(?s).*?-->")
    private let htmlEntityRegex = try? NSRegularExpression(pattern: "&(?:[A-Za-z][A-Za-z0-9]+|#\\d+|#x[0-9A-Fa-f]+);")
    private let tableRowRegex = try? NSRegularExpression(pattern: "(?m)^\\|.*\\|\\s*$")
    private let inlineCodeRegex = try? NSRegularExpression(pattern: "`[^`\\n]+`")
    private let fencedCodeRegex = try? NSRegularExpression(pattern: "(?s)```.*?```")
    private let htmlTagRegex = try? NSRegularExpression(
        pattern: "</?[A-Za-z][A-Za-z0-9:-]*\\b[^>]*?>",
        options: [.dotMatchesLineSeparators]
    )
    private let htmlAttributeRegex = try? NSRegularExpression(
        pattern: "\\b([A-Za-z_:][A-Za-z0-9_:\\-.]*)\\s*=\\s*(\"[^\"]*\"|'[^']*')"
    )

    private struct Palette {
        let headingColor: NSColor
        let mutedAccentColor: NSColor
        let emphasisColor: NSColor
        let linkColor: NSColor
        let codeColor: NSColor
        let codeBackgroundColor: NSColor
        let htmlTagColor: NSColor
        let htmlAttributeNameColor: NSColor
        let htmlAttributeValueColor: NSColor
        let htmlCommentColor: NSColor
    }

    private func palette(for textView: NSTextView) -> Palette {
        let isDarkMode = textView.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let hexes = MarkdownEditorThemePalette.tokenHexes(isDarkMode: isDarkMode)
        return Palette(
            headingColor: NSColor(hex: hexes.heading) ?? .systemBlue,
            mutedAccentColor: NSColor(hex: hexes.mutedAccent) ?? .secondaryLabelColor,
            emphasisColor: NSColor(hex: hexes.emphasis) ?? .systemPurple,
            linkColor: NSColor(hex: hexes.link) ?? .systemBlue,
            codeColor: NSColor(hex: hexes.code) ?? .systemBrown,
            codeBackgroundColor: NSColor(hex: hexes.codeBackground)?.withAlphaComponent(isDarkMode ? 0.55 : 0.9) ?? NSColor.quaternaryLabelColor.withAlphaComponent(0.2),
            htmlTagColor: NSColor(hex: hexes.htmlTag) ?? .systemBlue,
            htmlAttributeNameColor: NSColor(hex: hexes.htmlAttributeName) ?? .secondaryLabelColor,
            htmlAttributeValueColor: NSColor(hex: hexes.htmlAttributeValue) ?? .systemBlue,
            htmlCommentColor: NSColor(hex: hexes.htmlComment) ?? .tertiaryLabelColor
        )
    }

    func apply(to textView: NSTextView) {
        guard let textStorage = textView.textStorage else { return }
        let text = textView.string as NSString
        let fullRange = NSRange(location: 0, length: text.length)
        let selectedRanges = textView.selectedRanges
        let palette = palette(for: textView)

        textStorage.beginEditing()
        textStorage.setAttributes(
            [
                .font: baseFont,
                .foregroundColor: NSColor.textColor
            ],
            range: fullRange
        )

        applyRegex(headingRegex, in: text, storage: textStorage, attributes: [
            .foregroundColor: palette.headingColor,
            .font: strongFont
        ])
        applyRegex(quoteRegex, in: text, storage: textStorage, attributes: [
            .foregroundColor: palette.mutedAccentColor
        ])
        applyRegex(listMarkerRegex, in: text, storage: textStorage, attributes: [
            .foregroundColor: palette.mutedAccentColor,
            .font: strongFont
        ])
        applyRegex(strongRegex, in: text, storage: textStorage, attributes: [
            .foregroundColor: palette.emphasisColor,
            .font: strongFont
        ])
        applyRegex(emphasisRegex, in: text, storage: textStorage, attributes: [
            .foregroundColor: palette.emphasisColor
        ])
        applyRegex(linkRegex, in: text, storage: textStorage, attributes: [
            .foregroundColor: palette.linkColor
        ])
        applyRegex(htmlCommentRegex, in: text, storage: textStorage, attributes: [
            .foregroundColor: palette.htmlCommentColor
        ])
        applyHTMLTagAttributes(in: text, storage: textStorage, palette: palette)
        applyRegex(htmlEntityRegex, in: text, storage: textStorage, attributes: [
            .foregroundColor: palette.mutedAccentColor
        ])
        applyRegex(tableRowRegex, in: text, storage: textStorage, attributes: [
            .foregroundColor: palette.mutedAccentColor
        ])
        applyRegex(inlineCodeRegex, in: text, storage: textStorage, attributes: [
            .foregroundColor: palette.codeColor,
            .backgroundColor: palette.codeBackgroundColor
        ])
        applyRegex(fencedCodeRegex, in: text, storage: textStorage, attributes: [
            .foregroundColor: palette.codeColor,
            .backgroundColor: palette.codeBackgroundColor
        ])

        textStorage.endEditing()
        textView.selectedRanges = selectedRanges
    }

    private func applyRegex(
        _ regex: NSRegularExpression?,
        in text: NSString,
        storage: NSTextStorage,
        attributes: [NSAttributedString.Key: Any]
    ) {
        guard let regex else { return }
        let range = NSRange(location: 0, length: text.length)
        for match in regex.matches(in: text as String, range: range) {
            storage.addAttributes(attributes, range: match.range)
        }
    }

    private func applyHTMLTagAttributes(
        in text: NSString,
        storage: NSTextStorage,
        palette: Palette
    ) {
        guard let htmlTagRegex, let htmlAttributeRegex else { return }

        let fullRange = NSRange(location: 0, length: text.length)
        for tagMatch in htmlTagRegex.matches(in: text as String, range: fullRange) {
            storage.addAttributes([.foregroundColor: palette.htmlTagColor], range: tagMatch.range)

            let tagText = text.substring(with: tagMatch.range) as NSString
            let localRange = NSRange(location: 0, length: tagText.length)
            for attributeMatch in htmlAttributeRegex.matches(in: tagText as String, range: localRange) {
                guard attributeMatch.numberOfRanges >= 3 else { continue }
                let nameRange = attributeMatch.range(at: 1)
                let valueRange = attributeMatch.range(at: 2)
                let globalNameRange = NSRange(
                    location: tagMatch.range.location + nameRange.location,
                    length: nameRange.length
                )
                let globalValueRange = NSRange(
                    location: tagMatch.range.location + valueRange.location,
                    length: valueRange.length
                )
                storage.addAttributes([.foregroundColor: palette.htmlAttributeNameColor], range: globalNameRange)
                storage.addAttributes([.foregroundColor: palette.htmlAttributeValueColor], range: globalValueRange)
            }
        }
    }
}

struct MarkdownPanelView: View {
    @ObservedObject var panel: MarkdownPanel
    let onRequestPanelFocus: () -> Void

    @State private var saveErrorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Picker("Mode", selection: $panel.isPreviewMode) {
                    Text("Edit").tag(false)
                    Text("Preview").tag(true)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 220)

                Spacer(minLength: 8)

                if panel.isDirty {
                    Text("Unsaved")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Button("Save") {
                    do {
                        try panel.save()
                    } catch {
                        saveErrorMessage = error.localizedDescription
                    }
                }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(panel.fileURL == nil)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            Group {
                if panel.isPreviewMode {
                    MarkdownPreviewTextView(markdown: panel.text)
                } else {
                    MarkdownEditorTextView(text: $panel.text)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            onRequestPanelFocus()
        }
        .alert("Couldn’t Save Markdown File", isPresented: Binding(
            get: { saveErrorMessage != nil },
            set: { newValue in
                if !newValue {
                    saveErrorMessage = nil
                }
            }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(saveErrorMessage ?? "Unknown error")
        }
    }
}
