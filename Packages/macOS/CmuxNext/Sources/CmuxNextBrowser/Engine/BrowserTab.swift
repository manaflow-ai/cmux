public import AppKit
public import Foundation
public import Observation

/// One live page. Engine-neutral: the chrome, the App layer, and automation
/// talk only to this protocol.
///
/// Conforming types are `@Observable`, so `state`, `favicon`, and
/// `pendingPrompts` can be tracked with Observation.
@MainActor
public protocol BrowserTab: AnyObject, Observable, Sendable {
    var id: BrowserTabID { get }
    var engineKind: BrowserEngineKind { get }
    var profileID: BrowserProfileID { get }
    var presentation: BrowserPresentation { get }

    /// The view to place in the pane. For `.childWindow` engines this is the
    /// placeholder the child window tracks.
    var contentView: NSView { get }

    var state: BrowserTabState { get }
    var favicon: NSImage? { get }
    /// Unanswered permission requests and JavaScript dialogs, oldest first.
    var pendingPrompts: [BrowserPrompt] { get }

    var delegate: (any BrowserTabDelegate)? { get set }
    var keyRouter: (any BrowserKeyRouting)? { get set }

    func load(_ url: URL)
    func goBack()
    func goForward()
    func reload()
    func stop()

    /// Gives or removes keyboard focus from the page.
    func setFocused(_ focused: Bool)
    /// Shows or hides and pauses the page, synchronously, before returning.
    /// The App's content lifecycle is the only caller (one event per
    /// transition, in order); `.childWindow` engines hide their page window
    /// at once, which Chromium sees as the page becoming hidden.
    func setContentVisible(_ visible: Bool)

    /// Page pixels for hover previews and occlusion placeholders.
    func snapshot() async throws -> CGImage

    /// Page pixels for a tab thumbnail (hover card, drag image), taken each
    /// time a page leaves the screen. May trade fidelity for a cheaper
    /// capture than `snapshot()`; the default is `snapshot()`.
    func thumbnail() async throws -> CGImage

    /// Evaluates a script and returns its completion value.
    func evaluate(_ script: String, world: BrowserScriptWorld) async throws -> BrowserJSValue

    /// Highlights the next or previous match of `text`.
    func find(_ text: String, direction: BrowserFindDirection, caseSensitive: Bool) async -> BrowserFindResult
    func clearFind()

    func setZoom(_ zoom: Double)

    /// Leaves in-pane content fullscreen, if active.
    func exitContentFullscreen()

    func showDevTools()

    /// The favicon at `url` fetched as this tab would (the default is the app's cookieless fetch).
    func fetchFavicon(_ url: URL) async -> NSImage?

    /// An agent is driving this tab (browser automation): saved passwords
    /// stop filling in it for the rest of its life, so a page script cannot
    /// read one after an automated click. Agents sign in only through the
    /// secure sign-in sheet (plans/cmux-next/browser.md, "Secure sign-in").
    func markAgentDriven()

    /// Whether `markAgentDriven` has run on this page.
    var isAgentDriven: Bool { get }

    /// The tab's profile allows Chromium's password filling: false while an
    /// extension is the profile's password manager or the person turned
    /// autofill off (`PasswordFillPolicy`, plans/cmux-next/passwords.md).
    func setPasswordFillAllowedByProfile(_ allowed: Bool)

    /// Tears the page down. Pending prompts are dismissed. Idempotent.
    func close()
}

extension BrowserTab {
    public func thumbnail() async throws -> CGImage { try await snapshot() }

    /// Engines without Chromium password autofill have nothing to withhold.
    /// The favicon at `url` as this tab fetches it: the app's cookieless fetch, unless the
    /// engine can fetch through the tab's own context (a Chromium tab, cx-d0d.8).
    public func fetchFavicon(_ url: URL) async -> NSImage? {
        await BrowserFaviconLoader.shared.favicon(at: url, profile: profileID)
    }

    public func markAgentDriven() {}
    public var isAgentDriven: Bool { false }
    public func setPasswordFillAllowedByProfile(_ allowed: Bool) {}

    public func zoomIn() { setZoom(BrowserZoom.zoomIn(from: state.zoom)) }
    public func zoomOut() { setZoom(BrowserZoom.zoomOut(from: state.zoom)) }
    public func resetZoom() { setZoom(1) }

    public func evaluate(_ script: String) async throws -> BrowserJSValue {
        try await evaluate(script, world: .page)
    }

    /// Runs `body` as an async function in the page world and returns what
    /// it resolves to (automation waits). WebKit's `evaluateJavaScript` does
    /// not await a promise, so a WebKit tab calls the function instead; CEF's
    /// `evaluate` awaits one.
    public func evaluateAsync(_ body: String) async throws -> BrowserJSValue {
        if let tab = self as? WebKitTab { return try await WebKitPageAutomation(tab: tab).evaluateAsync(body) }
        return try await evaluate("(async () => {\n\(body)\n})()", world: .page)
    }

    /// Pixels of the whole document, not only the viewport (automation
    /// screenshots).
    public func fullPageSnapshot() async throws -> CGImage {
        if let tab = self as? WebKitTab { return try await WebKitPageAutomation(tab: tab).fullPageSnapshot() }
        if let tab = self as? CEFTab { return try await CEFFullPageCapture(tab: tab).run() }
        throw BrowserTabError.snapshotUnavailable
    }

    /// Every cookie of the tab's profile (automation).
    public func cookies() async throws -> [BrowserCookie] {
        if let tab = self as? WebKitTab { return await WebKitCookieStore(tab: tab).cookies() }
        if let tab = self as? CEFTab { return try await CEFCookieStore(tab: tab).cookies() }
        throw BrowserTabError.unsupported("cookies")
    }

    /// Stores `cookie` in the tab's profile.
    public func setCookie(_ cookie: BrowserCookie) async throws {
        if let tab = self as? WebKitTab { return try await WebKitCookieStore(tab: tab).set(cookie) }
        if let tab = self as? CEFTab { return try await CEFCookieStore(tab: tab).set(cookie) }
        throw BrowserTabError.unsupported("cookies")
    }

    /// Deletes the cookies with each one's name, domain and path.
    public func deleteCookies(_ cookies: [BrowserCookie]) async throws {
        if let tab = self as? WebKitTab { return await WebKitCookieStore(tab: tab).delete(cookies) }
        if let tab = self as? CEFTab { return try await CEFCookieStore(tab: tab).delete(cookies) }
        throw BrowserTabError.unsupported("cookies")
    }
}
