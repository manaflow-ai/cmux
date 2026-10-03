public import AppKit
public import CmuxNextDesign
public import CmuxNextSettings
import WebKit

/// The web Settings page in a page tab (plans/cmux-next/settings-react.md
/// sections 4-5): a transparent WKWebView over the window's one backdrop,
/// loading `cmux-settings://page/index.html`. Its requests go through
/// `SettingsPageBridge`; committed changes and theme changes are pushed to
/// the page through `window.cmuxSettingsBridge`.
@MainActor
public final class SettingsWebPageView: NSView, ThemeResponsive {
    /// What the page asks of the app besides settings operations.
    public struct Host {
        /// Theme names for the `ready` reply (the app's theme catalog).
        public var themeNames: () -> [String]
        /// `native.open {target: "section", section}`.
        public var openNativeSection: (String) -> Void
        /// `native.open {target: "cmuxJSON"}`.
        public var openConfigFile: () -> Void

        public init(themeNames: @escaping () -> [String],
                    openNativeSection: @escaping (String) -> Void, openConfigFile: @escaping () -> Void) {
            self.themeNames = themeNames
            self.openNativeSection = openNativeSection
            self.openConfigFile = openConfigFile
        }
    }

    let webView: WKWebView
    private let backend: any SettingsPageBackend
    private let bridge: SettingsPageBridge
    private let host: Host
    private weak var scope: ThemeScope?
    private var initialRoute: String?
    private var pageReady = false

    /// Nil when the bundled page is missing from the resource bundle.
    public init?(backend: any SettingsPageBackend, host: Host, scope: ThemeScope, initialRoute: String? = nil) {
        guard let root = SettingsPageSchemeHandler.bundledRoot() else { return nil }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(SettingsPageSchemeHandler(root: root), forURLScheme: SettingsPageSchemeHandler.scheme)
        let bridge = SettingsPageBridge(backend: backend)
        configuration.userContentController.addScriptMessageHandler(bridge, contentWorld: .page, name: SettingsPageBridge.name)
        webView = WKWebView(frame: .zero, configuration: configuration)
        self.backend = backend
        self.bridge = bridge
        self.host = host
        self.scope = scope
        self.initialRoute = initialRoute
        super.init(frame: .zero)
        webView.autoresizingMask = [.width, .height]
        webView.allowsBackForwardNavigationGestures = false
        webView.allowsLinkPreview = false
        // The page and every container are transparent; WebKit's opaque
        // backing would hide the window's backdrop. macOS has no public
        // switch, so this uses `_setDrawsBackground:` through KVC, checked
        // first (as the agent pane does).
        if webView.responds(to: NSSelectorFromString("_setDrawsBackground:")) {
            webView.setValue(false, forKey: "drawsBackground")
        }
        webView.underPageBackgroundColor = .clear
        #if DEBUG
        webView.isInspectable = true
        #endif
        setAccessibilityIdentifier("cmux.settings.webPage")
        addSubview(webView)
        bridge.pageOperation = { [weak self] operation, params in
            await self?.pageOperation(operation, params: params) ?? .null
        }
        backend.onChange = { [weak self] revision, keys in
            self?.dispatch(["type": "settings.changed", "revision": revision, "keys": keys])
        }
        scope.addResponder(self)
        webView.load(URLRequest(url: SettingsPageSchemeHandler.pageURL))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override var isFlipped: Bool { true }

    public override func layout() {
        super.layout()
        webView.frame = bounds
    }

    /// Shows `section`, or `key` revealed in its section, in the page.
    public func open(section: String?, key: String?) {
        guard let route = Self.route(section: section, key: key) else { return }
        guard pageReady else {
            initialRoute = route
            return
        }
        evaluate("window.location.hash = \(Self.literal("#" + route));")
    }

    public nonisolated static func route(section: String?, key: String?) -> String? {
        if let key, let descriptor = SettingsSchema.descriptor(for: key.split(separator: ".").map(String.init)) {
            return "/settings/\(descriptor.section.rawValue)?focus=\(descriptor.id)"
        }
        return section.map { "/settings/\($0)" }
    }

    // MARK: Theme

    public func themeDidChange() {
        guard pageReady, let scope else { return }
        guard let data = try? JSONSerialization.data(withJSONObject: SettingsPageTheme.values(scope.tokens)),
              let json = String(data: data, encoding: .utf8) else { return }
        evaluate("window.cmuxSettingsBridge?.applyTheme(\(json));")
    }

    // MARK: Page operations

    private func pageOperation(_ operation: String, params: JSONValue) async -> JSONValue {
        switch operation {
        case "ready":
            pageReady = true
            let theme = scope.flatMap { try? JSONValue.parse(JSONSerialization.data(withJSONObject: SettingsPageTheme.values($0.tokens))) }
            let route = initialRoute
            initialRoute = nil
            return [
                "locale": .string(Self.locale()),
                "theme": theme ?? .null,
                "domains": [
                    "themes": .array(host.themeNames().map(JSONValue.string)),
                    "font_families": .array(NSFontManager.shared.availableFontFamilies.map(JSONValue.string)),
                    "sounds": .array(SoundControl.systemSounds.map(JSONValue.string)),
                ],
                "initialRoute": route.map(JSONValue.string) ?? .null,
            ]
        case "native.open":
            if params["target"]?.stringValue == "cmuxJSON" {
                host.openConfigFile()
            } else if let section = params["section"]?.stringValue {
                host.openNativeSection(section)
            }
            return .object([:])
        case "sound.play":
            if let name = params["name"]?.stringValue { NSSound(named: NSSound.Name(name))?.play() }
            return .object([:])
        default:
            // preview / preview.end: the live preview overlay lands with the
            // daemon relay (slice b); the commit on release is the write.
            return .object([:])
        }
    }

    /// The app's language as the page's string tables name it.
    nonisolated static func locale() -> String {
        Bundle.main.preferredLocalizations.first ?? Locale.preferredLanguages.first ?? "en"
    }

    private func dispatch(_ event: [String: Any]) {
        guard pageReady, let data = try? JSONSerialization.data(withJSONObject: event),
              let json = String(data: data, encoding: .utf8) else { return }
        evaluate("window.cmuxSettingsBridge?.dispatch(\(json));")
    }

    private func evaluate(_ script: String) {
        webView.evaluateJavaScript(script, completionHandler: nil)
    }

    nonisolated static func literal(_ text: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [text])) ?? Data("[\"\"]".utf8)
        let array = String(decoding: data, as: UTF8.self)
        return String(array.dropFirst().dropLast())
    }
}
