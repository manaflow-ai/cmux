import AppKit
import SwiftUI
import WebKit

struct MarkdownCodeMirrorTheme: Equatable {
    let isDark: Bool
    let background: String
    let foreground: String
    let mutedForeground: String
    let border: String
    let mutedBackground: String
    let activeLine: String
    let selection: String
    let caret: String
    let accent: String
    let codeBackground: String
    let calloutBackground: String

    static func resolve(backgroundColor: NSColor, foregroundColor: NSColor) -> MarkdownCodeMirrorTheme {
        let base = backgroundColor.markdownOpaqueSRGB
        let foreground = foregroundColor.markdownOpaqueSRGB
        let isDark = !base.isLightColor
        let overlay: NSColor = isDark ? .white : .black
        let accentColor = NSColor.controlAccentColor.markdownOpaqueSRGB
        let mutedForeground = foreground.withAlphaComponent(isDark ? 0.68 : 0.72)
        let mutedBackground = base.markdownThemeOverlay(
            targetContrast: isDark ? 1.09 : 1.06,
            of: overlay
        )
        let activeLine = base.markdownThemeOverlay(
            targetContrast: isDark ? 1.055 : 1.035,
            of: overlay
        )
        let border = base.markdownThemeOverlay(
            targetContrast: isDark ? 1.92 : 1.43,
            of: overlay
        )
        let codeBackground = base.markdownThemeOverlay(
            targetContrast: isDark ? 1.16 : 1.12,
            of: overlay
        )
        let calloutBackground = accentColor.withAlphaComponent(isDark ? 0.16 : 0.10)

        return MarkdownCodeMirrorTheme(
            isDark: isDark,
            background: "transparent",
            foreground: foreground.markdownCSSColor,
            mutedForeground: mutedForeground.markdownCSSColor,
            border: border.markdownCSSColor,
            mutedBackground: mutedBackground.markdownCSSColor,
            activeLine: activeLine.markdownCSSColor,
            selection: accentColor.withAlphaComponent(isDark ? 0.34 : 0.22).markdownCSSColor,
            caret: foreground.markdownCSSColor,
            accent: accentColor.markdownCSSColor,
            codeBackground: codeBackground.markdownCSSColor,
            calloutBackground: calloutBackground.markdownCSSColor
        )
    }

    var payload: [String: Any] {
        [
            "isDark": isDark,
            "background": background,
            "foreground": foreground,
            "mutedForeground": mutedForeground,
            "border": border,
            "mutedBackground": mutedBackground,
            "activeLine": activeLine,
            "selection": selection,
            "caret": caret,
            "accent": accent,
            "codeBackground": codeBackground,
            "calloutBackground": calloutBackground
        ]
    }
}

@MainActor
protocol MarkdownCodeMirrorPanelEditor: AnyObject {
    func focusEditor()
    func selectFirstMatch(_ needle: String)
}

struct MarkdownCodeMirrorEditor: NSViewRepresentable {
    @ObservedObject var panel: MarkdownPanel
    let isVisibleInUI: Bool
    let theme: MarkdownCodeMirrorTheme
    let backgroundColor: NSColor
    let onRequestPanelFocus: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(panel: panel)
    }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.suppressesIncrementalRendering = false
        config.userContentController.add(context.coordinator, name: Coordinator.bridgeName)

        let webView = MarkdownEditorWebView(frame: .zero, configuration: config)
        webView.panel = panel
        webView.onPointerDown = onRequestPanelFocus
        webView.setValue(false, forKey: "drawsBackground")
        applyBackground(to: webView)
        applyAppearance(to: webView, isDark: theme.isDark)
        webView.allowsBackForwardNavigationGestures = false
        webView.allowsLinkPreview = false
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        if #available(macOS 13.3, *) {
#if DEBUG
            webView.isInspectable = true
#else
            webView.isInspectable = false
#endif
        }

        context.coordinator.panel = panel
        context.coordinator.webView = webView
        panel.attachCodeMirrorEditor(context.coordinator)
        context.coordinator.loadShell(theme: theme, initialMarkdown: panel.textContent)
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        context.coordinator.panel = panel
        panel.attachCodeMirrorEditor(context.coordinator)
        nsView.isHidden = !isVisibleInUI
        (nsView as? MarkdownEditorWebView)?.panel = panel
        (nsView as? MarkdownEditorWebView)?.onPointerDown = onRequestPanelFocus
        applyBackground(to: nsView)
        applyAppearance(to: nsView, isDark: theme.isDark)
        context.coordinator.update(markdown: panel.textContent, theme: theme)
    }

    static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
        nsView.configuration.userContentController.removeScriptMessageHandler(forName: Coordinator.bridgeName)
        nsView.navigationDelegate = nil
        nsView.uiDelegate = nil
        (nsView as? MarkdownEditorWebView)?.panel = nil
        (nsView as? MarkdownEditorWebView)?.onPointerDown = nil
        coordinator.panel?.detachCodeMirrorEditor(coordinator)
        if coordinator.webView === nsView {
            coordinator.webView = nil
        }
    }

    private func applyAppearance(to webView: WKWebView, isDark: Bool) {
        let appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
        if webView.appearance !== appearance {
            webView.appearance = appearance
        }
    }

    private func applyBackground(to webView: WKWebView) {
        webView.underPageBackgroundColor = backgroundColor
        webView.wantsLayer = true
        webView.layer?.backgroundColor = backgroundColor.cgColor
        webView.layer?.isOpaque = backgroundColor.alphaComponent >= 0.999
    }

    @MainActor
    final class Coordinator: NSObject, MarkdownCodeMirrorPanelEditor, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
        static let bridgeName = "cmuxMarkdownEditor"

        weak var webView: WKWebView?
        weak var panel: MarkdownPanel?

        private var pendingMarkdown = ""
        private var pendingTheme = MarkdownCodeMirrorTheme.resolve(
            backgroundColor: GhosttyBackgroundTheme.currentColor(),
            foregroundColor: .textColor
        )
        private var lastTheme: MarkdownCodeMirrorTheme?
        private var knownEditorMarkdown: String?
        private var isLoaded = false
        private var isBooted = false
        private var pendingFocus = false
        private var pendingSearchNeedle: String?

        init(panel: MarkdownPanel) {
            self.panel = panel
        }

        func loadShell(theme: MarkdownCodeMirrorTheme, initialMarkdown: String) {
            pendingMarkdown = initialMarkdown
            pendingTheme = theme
            lastTheme = theme
            knownEditorMarkdown = nil
            isLoaded = false
            isBooted = false
            webView?.loadHTMLString(
                MarkdownCodeMirrorAssets.shared.shellHTML(),
                baseURL: URL(fileURLWithPath: panel?.filePath ?? NSTemporaryDirectory())
            )
        }

        func update(markdown: String, theme: MarkdownCodeMirrorTheme) {
            pendingMarkdown = markdown
            pendingTheme = theme

            let themeChanged = lastTheme != theme
            if themeChanged {
                lastTheme = theme
            }

            guard isLoaded else { return }
            if !isBooted {
                bootEditor(markdown: markdown, theme: theme)
                return
            }
            if themeChanged {
                applyTheme(theme)
            }
            if knownEditorMarkdown != markdown {
                pushDocument(markdown)
            }
        }

        func focusEditor() {
            pendingFocus = true
            guard isLoaded, isBooted else { return }
            evaluate("window.cmuxMarkdownEditor && window.cmuxMarkdownEditor.focus();")
            pendingFocus = false
        }

        func selectFirstMatch(_ needle: String) {
            pendingSearchNeedle = needle
            guard isLoaded, isBooted else { return }
            applyPendingSearchNeedle()
        }

        private func bootEditor(markdown: String, theme: MarkdownCodeMirrorTheme) {
            guard let script = Self.bootScript(
                markdown: markdown,
                theme: theme,
                strings: Self.localizedStrings()
            ) else { return }
            evaluate(script)
        }

        private func pushDocument(_ markdown: String) {
            guard let script = Self.callScript(name: "setDocument", argument: markdown) else { return }
            knownEditorMarkdown = markdown
            evaluate(script)
        }

        private func applyTheme(_ theme: MarkdownCodeMirrorTheme) {
            guard let script = Self.callScript(name: "setTheme", argument: theme.payload) else { return }
            evaluate(script)
        }

        private func applyPendingSearchNeedle() {
            guard let needle = pendingSearchNeedle,
                  let script = Self.callScript(name: "selectFirstMatch", argument: needle) else { return }
            pendingSearchNeedle = nil
            evaluate(script)
        }

        private func runPendingWork() {
            if pendingFocus {
                focusEditor()
            }
            applyPendingSearchNeedle()
        }

        private func evaluate(_ script: String) {
            webView?.evaluateJavaScript(script, completionHandler: nil)
        }

        private static func bootScript(
            markdown: String,
            theme: MarkdownCodeMirrorTheme,
            strings: [String: String]
        ) -> String? {
            let payload: [String: Any] = [
                "document": markdown,
                "theme": theme.payload,
                "strings": strings
            ]
            guard let json = jsonLiteral(payload) else { return nil }
            return "window.cmuxMarkdownEditor && window.cmuxMarkdownEditor.boot(\(json));"
        }

        private static func callScript(name: String, argument: Any) -> String? {
            guard let json = jsonLiteral([argument]) else { return nil }
            return "window.cmuxMarkdownEditor && window.cmuxMarkdownEditor.\(name)(\(json)[0]);"
        }

        private static func jsonLiteral(_ value: Any) -> String? {
            guard JSONSerialization.isValidJSONObject(value),
                  let data = try? JSONSerialization.data(withJSONObject: value),
                  let json = String(data: data, encoding: .utf8) else { return nil }
            return json
        }

        private static func localizedStrings() -> [String: String] {
            [
                "taskComplete": String(localized: "markdown.editor.taskComplete", defaultValue: "Completed task"),
                "taskIncomplete": String(localized: "markdown.editor.taskIncomplete", defaultValue: "Incomplete task")
            ]
        }

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            guard message.name == Self.bridgeName,
                  let body = message.body as? [String: Any],
                  let action = body["action"] as? String else { return }

            switch action {
            case "ready":
                isBooted = true
                knownEditorMarkdown = pendingMarkdown
                runPendingWork()
            case "change":
                guard let markdown = body["markdown"] as? String else { return }
                knownEditorMarkdown = markdown
                panel?.updateTextContent(markdown)
            case "save":
                panel?.saveTextContent()
            case "openMarkdownFile":
                guard let rawPath = body["path"] as? String else { return }
                panel?.openLinkedMarkdownFile(rawPath: rawPath)
            case "error":
#if DEBUG
                if let message = body["message"] as? String {
                    NSLog("MarkdownCodeMirrorEditor error: \(message)")
                }
#endif
                break
            default:
                break
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            isLoaded = true
            bootEditor(markdown: pendingMarkdown, theme: pendingTheme)
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            if navigationAction.navigationType == .linkActivated,
               let url = navigationAction.request.url {
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }

        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            if let url = navigationAction.request.url {
                NSWorkspace.shared.open(url)
            }
            return nil
        }
    }
}

final class MarkdownEditorWebView: WKWebView {
    weak var panel: MarkdownPanel?
    var onPointerDown: (() -> Void)?
    private var pendingSaveShortcutChordPrefix: ShortcutStroke?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        PaneFirstClickFocusSettings.isEnabled()
    }

    override func mouseDown(with event: NSEvent) {
        onPointerDown?()
        super.mouseDown(with: event)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        panel?.retryPendingFocus()
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
