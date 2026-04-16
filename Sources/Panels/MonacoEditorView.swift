import AppKit
#if DEBUG
import Bonsplit
#endif
import Combine
import SwiftUI
import WebKit

/// Monaco-based editor surface. Runs the bundled Vite app inside a WKWebView
/// and mirrors buffer + view-state across the JS bridge so save/restore
/// behavior matches the native `EditorPanelView` backend.
struct MonacoEditorView: View {
    @ObservedObject var panel: EditorPanel
    let isFocused: Bool
    let isVisibleInUI: Bool
    let portalPriority: Int
    let onRequestPanelFocus: () -> Void

    @State private var focusFlashOpacity: Double = 0.0
    @State private var focusFlashAnimationGeneration: Int = 0
    @State private var ghosttyBackground: Color = Color(nsColor: NSColor(white: 0.12, alpha: 1.0))
    @State private var ghosttyForeground: Color = Color(nsColor: NSColor(white: 0.9, alpha: 1.0))

    var body: some View {
        Group {
            if panel.isFileUnavailable {
                fileUnavailableView
            } else {
                VStack(spacing: 0) {
                    filePathHeader
                        .padding(.leading, 8)
                        .padding(.trailing, 12)
                        .frame(height: 24)
                    MonacoWebViewRepresentable(
                        panel: panel,
                        isFocused: isFocused,
                        onRequestPanelFocus: onRequestPanelFocus
                    )
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ghosttyBackground)
        .overlay {
            RoundedRectangle(cornerRadius: FocusFlashPattern.ringCornerRadius)
                .stroke(cmuxAccentColor().opacity(focusFlashOpacity), lineWidth: 3)
                .shadow(color: cmuxAccentColor().opacity(focusFlashOpacity * 0.35), radius: 10)
                .padding(FocusFlashPattern.ringInset)
                .allowsHitTesting(false)
        }
        .onChange(of: panel.focusFlashToken) { _ in
            triggerFocusFlashAnimation()
        }
        .onAppear { refreshHeaderPalette() }
        .onReceive(NotificationCenter.default.publisher(for: .ghosttyConfigDidReload)) { _ in
            refreshHeaderPalette()
        }
        .onReceive(NotificationCenter.default.publisher(for: .ghosttyDefaultBackgroundDidChange)) { _ in
            refreshHeaderPalette()
        }
    }

    private var filePathHeader: some View {
        HStack(spacing: 0) {
            Text(panel.filePath)
                .font(.system(size: 11))
                .foregroundColor(ghosttyForeground.opacity(0.55))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
        }
    }

    private func refreshHeaderPalette() {
        let config = GhosttyConfig.load(useCache: false)
        ghosttyBackground = Color(nsColor: config.backgroundColor)
        ghosttyForeground = Color(nsColor: config.foregroundColor)
    }

    private var fileUnavailableView: some View {
        VStack(spacing: 12) {
            Image(systemName: "doc.questionmark")
                .font(.system(size: 40))
                .foregroundColor(.secondary)
            Text(String(localized: "editor.fileUnavailable.title", defaultValue: "File unavailable"))
                .font(.headline)
                .foregroundColor(.primary)
            Text(panel.filePath)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 24)
            Text(String(localized: "editor.fileUnavailable.message", defaultValue: "The file may have been moved or deleted."))
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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

// MARK: - WKWebView bridge

private struct MonacoWebViewRepresentable: NSViewRepresentable {
    let panel: EditorPanel
    let isFocused: Bool
    let onRequestPanelFocus: () -> Void

    func makeCoordinator() -> MonacoEditorCoordinator {
        MonacoEditorCoordinator(panel: panel, onRequestPanelFocus: onRequestPanelFocus)
    }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let schemeHandler = MonacoSchemeHandler()
        config.setURLSchemeHandler(schemeHandler, forURLScheme: MonacoSchemeHandler.scheme)
        let userContentController = WKUserContentController()
        userContentController.add(context.coordinator, name: "cmux")
        config.userContentController = userContentController
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")

        let webView = MonacoHostingWebView(frame: .zero, configuration: config)
        webView.onClickRequestFocus = { [weak coordinator = context.coordinator] in
            coordinator?.requestExternalFocusAcknowledgement()
        }
        webView.onSaveRequested = { [weak coordinator = context.coordinator] in
            coordinator?.handleHostSaveShortcut()
        }
        // Keep the webview opaque so WindowServer can composite it direct-to-
        // screen. Transparent WKWebViews fall back to an alpha-blended path
        // that adds perceptible input lag during typing. Ghostty-themed
        // background is painted by the HTML body so there's no visible flash.
        webView.allowsBackForwardNavigationGestures = false
        webView.navigationDelegate = context.coordinator

        context.coordinator.webView = webView
        context.coordinator.schemeHandler = schemeHandler

        if let url = URL(string: "\(MonacoSchemeHandler.scheme)://editor/index.html") {
            webView.load(URLRequest(url: url))
        }

        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.panel = panel
        context.coordinator.onRequestPanelFocus = onRequestPanelFocus
        context.coordinator.syncContentIfNeeded()
        // Do NOT refocus on every updateNSView — SwiftUI re-evaluates this view
        // on every panel.content change, and calling makeFirstResponder +
        // evaluateJavaScript("cmux.focus") per keystroke blocks the main
        // thread while WebKit is trying to render. Only apply focus on a
        // false→true transition via updatedFocusIfChanged.
        context.coordinator.updateFocusIfChanged(newValue: isFocused)
    }
}

// MARK: - Coordinator

@MainActor
final class MonacoEditorCoordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    var panel: EditorPanel
    var onRequestPanelFocus: () -> Void
    weak var webView: WKWebView?
    var schemeHandler: MonacoSchemeHandler?

    private var isReady = false
    private var lastSyncedContent: String?
    private var panelSubscriptions: Set<AnyCancellable> = []
    private var lastIsFocused: Bool = false

    init(panel: EditorPanel, onRequestPanelFocus: @escaping () -> Void) {
        self.panel = panel
        self.onRequestPanelFocus = onRequestPanelFocus
        super.init()
        panel.backendFlush = { [weak self] in
            await self?.flushBufferFromMonaco() ?? true
        }
        panel.backendAfterSave = { [weak self] in
            self?.markMonacoClean()
        }
        panel.backendFocus = { [weak self] in
            guard let self else { return false }
            self.focusEditor()
            return true
        }
        // Only observe content changes that were NOT originated by Monaco
        // itself. When Monaco posts a `changed` message and we set
        // `panel.content = value`, this sink would fire and push the same
        // content back into the webview via evaluateJavaScript. The Combine
        // round-trip happens on every keystroke and colides with WebKit
        // rendering, which is where the jank comes from.
        panel.$content
            .dropFirst()
            .sink { [weak self] newValue in
                guard let self else { return }
                if self.lastSyncedContent == newValue { return }
                self.syncContentIfNeeded()
            }
            .store(in: &panelSubscriptions)

        // Rebroadcast theme whenever the Ghostty config reloads so Monaco stays
        // in sync with terminal color edits (theme switch, palette override…).
        NotificationCenter.default.publisher(for: .ghosttyConfigDidReload)
            .sink { [weak self] _ in
                self?.sendTheme()
            }
            .store(in: &panelSubscriptions)
        // Ghostty broadcasts this one from the terminal surfaces themselves when
        // the default background flips, even before the config re-parse completes.
        NotificationCenter.default.publisher(for: .ghosttyDefaultBackgroundDidChange)
            .sink { [weak self] _ in
                self?.sendTheme()
            }
            .store(in: &panelSubscriptions)
    }

    // MARK: - Bridge inbound

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "cmux", let dict = message.body as? [String: Any] else { return }
        guard let type = dict["type"] as? String else { return }
        switch type {
        case "ready":
            handleReady()
        case "changed":
            handleChanged(payload: dict)
        case "dirty":
            if let isDirty = dict["isDirty"] as? Bool {
                // Flip the panel's dirty flag immediately so Cmd+W or
                // workspace-close see the correct state even when the
                // debounced `changed` hasn't landed yet.
                panel.setBackendDirty(isDirty)
            }
        case "saveRequested":
            Task { @MainActor [weak self] in
                await self?.performSaveAfterFlush()
            }
        case "viewState":
            handleViewState(payload: dict)
        case "debugLog":
            // JS-side console forwarding is off by default; if re-enabled for
            // debugging, messages land here.
            #if DEBUG
            if let msg = dict["msg"] as? String {
                dlog("monaco.js \(msg)")
            }
            #endif
        default:
            break
        }
    }

    private func handleReady() {
        isReady = true
        sendTheme()
        sendInitialState()
        // If the panel was already focused before Monaco finished booting,
        // `focusEditor()` skipped the JS focus command because `isReady`
        // was false and `updateFocusIfChanged` then flipped `lastIsFocused`
        // to true, preventing any later transition-based delivery. Retry
        // now so keystrokes land in the editor on first-open / workspace
        // switch without the user having to click. Explicitly dispatch
        // the JS focus command — `focusEditor()` would early-return when
        // AppKit first-responder is already inside the webview (common
        // race outcome), leaving Monaco's internal input field still
        // unfocused.
        if lastIsFocused {
            focusEditor()
            send(command: ["kind": "focus"])
        }
    }

    private func handleChanged(payload: [String: Any]) {
        guard let value = payload["value"] as? String else { return }
        if panel.content != value {
            // Set lastSyncedContent BEFORE publishing content so the
            // `panel.$content` subscriber can short-circuit without doing a
            // full-string compare — we just wrote the value, no need to
            // re-push it back into Monaco.
            lastSyncedContent = value
            panel.content = value
            panel.markDirty()
        }
        if let cursor = payload["cursor"] as? [String: Any] {
            if let offset = cursor["offset"] as? Int { panel.cursorLocation = offset }
            if let length = cursor["length"] as? Int { panel.cursorLength = length }
        }
    }

    func requestExternalFocusAcknowledgement() {
        onRequestPanelFocus()
        focusEditor()
    }

    /// Triggered by the configured `saveEditorFile` keyboard shortcut via
    /// `MonacoHostingWebView.performKeyEquivalent`. Routes through the same
    /// flush-then-save path that `saveRequested` uses so both paths stay
    /// consistent.
    func handleHostSaveShortcut() {
        Task { @MainActor [weak self] in
            await self?.performSaveAfterFlush()
        }
    }

    private func performSaveAfterFlush() async {
        // Flush the live buffer over the bridge first so the disk write
        // includes the last keystroke, not the last debounced snapshot.
        // If the bridge is unavailable (webview still loading, or Monaco
        // not booted yet), bail out instead of saving — otherwise we'd
        // clobber the file with the current `panel.content`, which may
        // predate the user's recent edits.
        guard await flushBufferFromMonaco() else { return }
        guard panel.isDirty else { return }
        if panel.save() {
            // Tell Monaco the current version is now the clean baseline so
            // the next keystroke emits a fresh dirty=true transition; without
            // this the dirty-ping short-circuit would keep Monaco reporting
            // clean until the debounced `changed` re-establishes dirt.
            markMonacoClean()
        } else {
            EditorSaveAlert.show(for: panel)
        }
    }

    private func markMonacoClean() {
        webView?.evaluateJavaScript(
            "window.cmuxMonaco && window.cmuxMonaco.markSaved && window.cmuxMonaco.markSaved()",
            completionHandler: nil
        )
    }

    /// Pull the live buffer from Monaco over the JS bridge and write it into
    /// `panel.content`. Used by the save path so a Cmd+S right after a
    /// keystroke (before the 120ms debounced `changed` lands) still saves
    /// the correct text.
    ///
    /// If the bridge is not yet available (webview still loading), return
    /// `null` from JS so Swift can distinguish "no buffer available" from
    /// "buffer is the empty string". A caller that proceeds to save must
    /// treat that as a no-op to avoid writing an empty file over the user's
    /// real content before Monaco has booted.
    @discardableResult
    func flushBufferFromMonaco() async -> Bool {
        guard let webView else { return false }
        let script = "(window.cmuxMonaco && typeof window.cmuxMonaco.getValue === 'function') ? window.cmuxMonaco.getValue() : null"
        let result = try? await webView.evaluateJavaScript(script)
        // evaluateJavaScript maps JS null → `NSNull`. Treat anything that
        // isn't a concrete String as "bridge unavailable" and leave
        // panel.content untouched.
        guard let value = result as? String else { return false }
        if panel.content != value {
            lastSyncedContent = value
            panel.content = value
            panel.markDirty()
        }
        return true
    }

    private func handleViewState(payload: [String: Any]) {
        if let cursor = payload["cursor"] as? [String: Any] {
            if let offset = cursor["offset"] as? Int { panel.cursorLocation = offset }
            if let length = cursor["length"] as? Int { panel.cursorLength = length }
        }
        if let frac = payload["scrollTopFraction"] as? Double {
            panel.scrollTopFraction = frac
        }
        if let vs = payload["monacoViewState"] as? String, !vs.isEmpty {
            panel.monacoViewState = vs
        }
        panel.lastOpenedAt = Date().timeIntervalSince1970
    }

    // MARK: - Bridge outbound

    func syncContentIfNeeded() {
        guard isReady else { return }
        if lastSyncedContent == panel.content { return }
        lastSyncedContent = panel.content
        sendSetText(preserveViewState: true)
    }

    func focusEditor() {
        guard let webView else { return }
        // WKWebView's real responder is typically an internal descendant view
        // (WKWebViewDerivedResponder). Walk the responder chain and skip if
        // any ancestor of the current first responder is our webview — we are
        // already focused, just into a subview.
        if let current = webView.window?.firstResponder as? NSView,
           current.isDescendant(of: webView) {
            return
        }
        webView.window?.makeFirstResponder(webView)
        guard isReady else { return }
        send(command: ["kind": "focus"])
    }

    func updateFocusIfChanged(newValue: Bool) {
        defer { lastIsFocused = newValue }
        // Only apply focus on a transition into focused state. Same-state
        // SwiftUI invalidations (driven by @Published panel.content updates
        // during typing) must not re-run makeFirstResponder + evaluateJavaScript.
        guard newValue, newValue != lastIsFocused else { return }
        focusEditor()
    }


    private func sendInitialState() {
        sendSetText(preserveViewState: false)
        restoreView()
    }

    private func sendSetText(preserveViewState: Bool) {
        let lang = MonacoLanguageResolver.languageId(for: panel.filePath)
        send(command: [
            "kind": "setText",
            "value": panel.content,
            "languageId": lang,
            "preserveViewState": preserveViewState,
        ])
    }

    private func restoreView() {
        send(command: [
            "kind": "restoreViewState",
            "monacoViewState": panel.monacoViewState ?? "",
            "scrollTopFraction": panel.scrollTopFraction,
            "cursorOffset": panel.cursorLocation,
            "cursorLength": panel.cursorLength,
        ])
    }

    private func sendTheme() {
        let palette = MonacoThemeResolver.currentPalette()
        var payload: [String: Any] = [
            "kind": "setTheme",
            "isDark": palette.isDark,
            "backgroundHex": palette.backgroundHex,
            "foregroundHex": palette.foregroundHex,
            "fontFamily": palette.fontFamily,
            "fontSize": palette.fontSize,
        ]
        if let cursor = palette.cursorHex { payload["cursorHex"] = cursor }
        if let selection = palette.selectionBackgroundHex { payload["selectionBackgroundHex"] = selection }
        if let ansi = palette.ansi, !ansi.isEmpty { payload["ansi"] = ansi }
        send(command: payload)
    }

    private func send(command: [String: Any]) {
        guard let webView,
              let data = try? JSONSerialization.data(withJSONObject: command),
              let json = String(data: data, encoding: .utf8) else { return }
        let script = "window.cmuxMonaco && window.cmuxMonaco.apply(\(json));"
        webView.evaluateJavaScript(script, completionHandler: nil)
    }
}

// MARK: - Custom WKWebView host

/// `WKWebView` subclass used by the Monaco panel. Ensures we always become the
/// AppKit first responder on mouseDown so Cmd+A, Cmd+C, arrow keys, etc. reach
/// Monaco inside the WKWebView, and forwards a callback to the SwiftUI side
/// for panel-focus bookkeeping.
final class MonacoHostingWebView: WKWebView {
    var onClickRequestFocus: (() -> Void)?
    /// Invoked when the user triggers the configured
    /// `KeyboardShortcutSettings.saveEditorFile` binding. The Monaco backend
    /// does not register its own Cmd+S command so users can rebind or
    /// disable save via settings.
    var onSaveRequested: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        if window?.firstResponder !== self {
            window?.makeFirstResponder(self)
        }
        onClickRequestFocus?()
        super.mouseDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if KeyboardShortcutSettings.shortcut(for: .saveEditorFile).matches(event: event) {
            onSaveRequested?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

// MARK: - URL scheme handler

final class MonacoSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "cmux-monaco"

    private lazy var bundleRoot: URL? = {
        // `MonacoBundle` is copied into the .app's Resources/ at build time.
        Bundle.main.resourceURL?.appendingPathComponent("MonacoBundle", isDirectory: true)
    }()

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url, let root = bundleRoot else {
            urlSchemeTask.didFailWithError(NSError(domain: "cmux.monaco", code: 1))
            return
        }

        // Normalize path: `cmux-monaco://editor/index.html` → Resources/MonacoBundle/index.html
        var relative = url.path
        if relative.isEmpty || relative == "/" {
            relative = "/index.html"
        }
        let fileURL = root.appendingPathComponent(relative, isDirectory: false).standardizedFileURL

        // Prevent escaping the bundle root.
        guard fileURL.path.hasPrefix(root.standardizedFileURL.path) else {
            urlSchemeTask.didFailWithError(NSError(domain: "cmux.monaco", code: 2))
            return
        }

        guard let data = try? Data(contentsOf: fileURL) else {
            urlSchemeTask.didFailWithError(NSError(
                domain: "cmux.monaco",
                code: 404,
                userInfo: [NSLocalizedDescriptionKey: "not found: \(fileURL.path)"]
            ))
            return
        }

        let mime = MonacoSchemeHandler.mimeType(for: fileURL.pathExtension)
        let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: [
                "Content-Type": mime,
                "Content-Length": "\(data.count)",
                "Cache-Control": "no-store",
            ]
        )!
        urlSchemeTask.didReceive(response)
        urlSchemeTask.didReceive(data)
        urlSchemeTask.didFinish()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {}

    private static func mimeType(for ext: String) -> String {
        switch ext.lowercased() {
        case "html": return "text/html; charset=utf-8"
        case "js", "mjs": return "application/javascript; charset=utf-8"
        case "css": return "text/css; charset=utf-8"
        case "json", "map": return "application/json; charset=utf-8"
        case "svg": return "image/svg+xml"
        case "ttf": return "font/ttf"
        case "woff": return "font/woff"
        case "woff2": return "font/woff2"
        case "wasm": return "application/wasm"
        default: return "application/octet-stream"
        }
    }
}

// MARK: - Language + theme helpers

enum MonacoLanguageResolver {
    static func languageId(for filePath: String) -> String {
        let ext = (filePath as NSString).pathExtension.lowercased()
        switch ext {
        // Web
        case "js", "mjs", "cjs", "jsx": return "javascript"
        case "ts", "tsx": return "typescript"
        case "json", "jsonc": return "json"
        case "html", "htm", "xhtml": return "html"
        case "css": return "css"
        case "scss": return "scss"
        case "less": return "less"
        case "xml", "xsd", "xsl", "xslt", "plist": return "xml"
        case "svg": return "xml"

        // Docs / markup
        case "md", "markdown", "mdown", "mdwn", "mdx": return "markdown"
        case "rst": return "restructuredtext"
        case "tex": return "plaintext"  // Monaco basic-languages lacks LaTeX

        // Systems
        case "c", "h": return "c"
        case "cc", "cpp", "hpp", "hh", "cxx", "cppm", "ixx": return "cpp"
        case "m", "mm": return "objective-c"
        case "rs": return "rust"
        case "go": return "go"
        case "zig": return "zig"
        case "swift": return "swift"

        // JVM
        case "java": return "java"
        case "kt", "kts": return "kotlin"
        case "scala", "sc": return "scala"
        case "groovy": return "java"
        case "clj", "cljs", "cljc", "edn": return "clojure"

        // .NET / Functional
        case "cs": return "csharp"
        case "fs", "fsx", "fsi": return "fsharp"
        case "vb": return "vb"

        // Python / data
        case "py", "pyi", "pyw": return "python"
        case "r": return "r"
        case "jl": return "julia"

        // Scripting
        case "sh", "bash", "zsh", "ksh": return "shell"
        case "fish": return "shell"
        case "ps1", "psm1", "psd1": return "powershell"
        case "pl", "pm": return "perl"
        case "rb", "rbi", "ru", "rake", "gemspec": return "ruby"
        case "lua": return "lua"
        case "tcl": return "tcl"

        // Mobile / web frameworks
        case "dart": return "dart"
        case "vue": return "html"
        case "svelte": return "html"
        case "php", "phtml": return "php"
        case "twig": return "twig"
        case "hbs", "handlebars": return "handlebars"
        case "pug", "jade": return "pug"

        // Query / data formats
        case "sql", "psql", "mysql": return "sql"
        case "graphql", "gql": return "graphql"
        case "proto": return "protobuf"
        case "toml": return "ini"
        case "ini", "cfg", "conf", "properties": return "ini"
        case "yml", "yaml": return "yaml"
        case "csv", "tsv": return "plaintext"

        // Infra
        case "tf", "tfvars", "hcl": return "hcl"
        case "dockerfile": return "dockerfile"
        case "containerfile": return "dockerfile"
        case "bicep": return "bicep"

        // Misc / functional / FP / other
        case "ex", "exs": return "elixir"
        case "elm": return "elm"
        case "hs", "lhs": return "scheme"  // Monaco has no Haskell; Scheme is the closest built-in Lisp/FP tokenizer
        case "scm", "ss", "rkt": return "scheme"
        case "lisp", "lsp", "el": return "scheme"
        case "ml", "mli": return "fsharp"  // OCaml → F# tokenizer is close enough for basic highlighting
        case "erl", "hrl": return "plaintext"  // Monaco has no Erlang tokenizer
        case "sol": return "solidity"
        case "wgsl": return "wgsl"
        case "nim", "nims": return "plaintext"
        case "abap": return "abap"
        case "apex", "cls", "trigger": return "apex"

        // Shell-adjacent / config
        case "diff", "patch": return "plaintext"
        case "log", "txt": return "plaintext"
        case "env": return "shell"

        default:
            // Filenames with no extension: match on basename for common files.
            let basename = (filePath as NSString).lastPathComponent.lowercased()
            switch basename {
            case "dockerfile", "containerfile": return "dockerfile"
            case "makefile", "gnumakefile", "bsdmakefile": return "plaintext"  // no basic-language
            case "rakefile", "gemfile", "guardfile", "capfile", "podfile":
                return "ruby"
            case "cmakelists.txt": return "plaintext"
            case "package.json", "tsconfig.json", "tsconfig.build.json":
                return "json"
            case "cargo.toml", "pyproject.toml": return "ini"
            case ".zshrc", ".zshenv", ".zprofile", ".bashrc", ".bash_profile",
                 ".profile", ".envrc":
                return "shell"
            case ".gitignore", ".gitattributes", ".dockerignore",
                 ".npmignore", ".eslintignore":
                return "plaintext"
            default:
                return "plaintext"
            }
        }
    }
}

/// Snapshot of a theme pushed to Monaco.
struct MonacoPalette {
    let isDark: Bool
    let backgroundHex: String
    let foregroundHex: String
    let cursorHex: String?
    let selectionBackgroundHex: String?
    /// ANSI indices 0..15 as lowercase `#rrggbb`. Empty when Ghostty hasn't
    /// provided a palette (falls back to Monaco built-in theme colors).
    let ansi: [String]?
    let fontFamily: String
    let fontSize: Double
}

enum MonacoThemeResolver {
    /// Build a MonacoPalette from the currently loaded GhosttyConfig so
    /// Monaco matches the terminal surfaces visually. Force-refreshes the
    /// cache so theme switches in ~/.config/ghostty/config are picked up
    /// immediately after `ghosttyConfigDidReload`.
    @MainActor
    static func currentPalette() -> MonacoPalette {
        let config = GhosttyConfig.load(useCache: false)
        let isDark = !config.backgroundColor.isLightColor
        let bg = config.backgroundColor.hexString()
        let fg = config.foregroundColor.hexString()
        let cursor = config.cursorColor.hexString()
        let selection = config.selectionBackground.hexString(includeAlpha: false)

        var ansi: [String] = []
        ansi.reserveCapacity(16)
        for index in 0..<16 {
            guard let color = config.palette[index] else {
                ansi.removeAll()
                break
            }
            ansi.append(color.hexString())
        }

        #if DEBUG
        let themeDescription = config.theme ?? "<none>"
        let paletteSummary = (0..<16)
            .map { index -> String in
                guard let c = config.palette[index] else { return "\(index):nil" }
                return "\(index):\(c.hexString())"
            }
            .joined(separator: " ")
        dlog(
            "monaco.theme theme=\(themeDescription) bg=\(bg) fg=\(fg) cursor=\(cursor) selection=\(selection) isDark=\(isDark ? 1 : 0) font=\(config.fontFamily)/\(config.fontSize) palette=[\(paletteSummary)]"
        )
        #endif

        return MonacoPalette(
            isDark: isDark,
            backgroundHex: bg,
            foregroundHex: fg,
            cursorHex: cursor,
            selectionBackgroundHex: selection,
            ansi: ansi.isEmpty ? nil : ansi,
            fontFamily: config.fontFamily,
            fontSize: Double(config.fontSize)
        )
    }
}
