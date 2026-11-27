public import Foundation
import AppKit
import CmuxNextCompat

/// A page's links to other apps (mailto:, tel:, an app's own scheme), from a
/// click in the main frame, in both engines (cx-d0d.22). A non-gesture
/// navigation (such as an OAuth return) reaches this path too and must still
/// ask before opening its app, without inheriting a saved permission from the
/// previously committed page. Chromium asks before the first launch for each
/// site and scheme. WebKit opens well-known schemes immediately after a click.
/// The tab's prompt bar offers Open, Cancel, and "Always allow"
/// for the site, remembered (user defaults; never for a page with no
/// origin, which would share one choice). A scheme no app opens does
/// nothing. In DEBUG builds launched with
/// `CMUX_NEXT_TEST_RECORD_EXTERNAL_OPENS=1` opens are recorded instead, so a
/// live test never starts Mail (`debug.browser.external_opens`).
///
/// This app's own schemes (every `CFBundleURLSchemes` in its Info.plist:
/// `cmux`, `cmux-nightly`, a dev tag's) never go through Launch Services from a
/// cmux tab: the app is already here. A sign-in or GitHub return
/// (``isOwnHandoff``) goes straight to the app's open-URL route
/// (``openOwnURL``) with no prompt, and the tab the flow opened closes
/// (``closesHandoffTab``), so the focus goes back to the pane that started
/// it. Any other link in an own scheme still asks, then routes in-process,
/// never to another cmux build. Leo, 2026-11-25: "it says it wants to open
/// it in the cmux app but if you're using the cmux browser to do that then
/// it should already know".
@MainActor
public final class BrowserExternalApps {
    public static let shared = BrowserExternalApps()

    /// Schemes WebKit opens without asking after a click: mail, phone and
    /// messages, and the apps people open from web pages every day (meetings,
    /// chat, editors).
    static let wellKnownSchemes: Set<String> = [
        "mailto", "tel", "sms", "facetime", "facetime-audio", "maps",
        "zoommtg", "zoomus", "msteams", "slack", "discord", "spotify",
        "vscode", "vscode-insiders", "cursor", "figma", "linear", "notion",
    ]
    private static let defaultsKey = "CmuxNextBrowser.externalSchemes"
    private let defaults: UserDefaults

    #if DEBUG
    /// The URLs a recording build would have opened, oldest first.
    public private(set) var recorded: [URL] = []
    private let records = ProcessInfo.processInfo.environment["CMUX_NEXT_TEST_RECORD_EXTERNAL_OPENS"] == "1"

    public func clearRecorded() {
        recorded.removeAll()
    }
    #endif

    /// This build's URL schemes, lowercased (Info.plist `CFBundleURLTypes`). Tests set their own: a test
    /// bundle registers none.
    var ownSchemes: Set<String>
    /// The app's own open-URL route (AppDelegate's, the one macOS uses). Nil:
    /// own-scheme links go through Launch Services like any other app's.
    public var openOwnURL: (@MainActor (URL) -> Void)?
    /// An own-scheme URL that finishes a flow this app started (sign-in
    /// callback, GitHub install return): handed off without a prompt.
    public var isOwnHandoff: (@MainActor (URL) -> Bool)?
    /// Whether a tab whose first page was this URL was opened for the flow
    /// (a sign-in or GitHub install page), so it closes once handed off.
    public var closesHandoffTab: (@MainActor (URL?) -> Bool)?
    /// An https page that is really a return to this app (GitHub's return to the App's Setup URL for a connect this
    /// build started): the own-scheme link it stands for, else nil. The tab hands it over before the page loads, so no
    /// console page shows and nothing asks to reopen the app the person is in.
    public var ownReturn: (@MainActor (URL) -> URL?)?

    /// `url` (a main-frame https navigation) handed to the app instead of loading when ``ownReturn`` takes it: the
    /// app's own route, and the flow's tab closes as an own-scheme handoff's does. False: it loads.
    func handOffReturn(_ url: URL, firstPage: URL?, close: (() -> Void)?) -> Bool {
        guard let own = ownReturn?(url), let route = openOwnURL else { return false }
        route(own)
        if closesHandoffTab?(firstPage) == true { close?() }
        return true
    }

    /// An own-scheme link that returns from a flow the app opened a tab for (Settings > Connections'
    /// `<scheme>://settings/integrations`): handed off without a prompt only from that tab
    /// (``noteFlowPage(_:)``), which then closes.
    public var isFlowReturn: (@MainActor (URL) -> Bool)?
    /// Pages the app opened a tab for to run a flow (the cmux sign-in, a connection's authorize page),
    /// newest last. A vendor's page need not look like a ``SignInPage``, so the tab is known by the
    /// address it was opened at, not guessed from it.
    private var flowPages: [String] = []
    private static let flowPageLimit = 16

    /// Records that the app is opening a tab at `url` for a flow whose return hands back to the app,
    /// so that tab's return goes straight to the app and the tab closes (``openOwn``).
    public func noteFlowPage(_ url: URL) {
        flowPages.removeAll { $0 == url.absoluteString }
        flowPages.append(url.absoluteString)
        if flowPages.count > Self.flowPageLimit { flowPages.removeFirst(flowPages.count - Self.flowPageLimit) }
    }

    /// Whether a tab that first loaded `requested` (and first showed `first`) was opened for a flow.
    func startedFlow(first: URL?, requested: URL?) -> Bool {
        if closesHandoffTab?(first) == true || closesHandoffTab?(requested) == true { return true }
        return [first, requested].contains { page in page.map { flowPages.contains($0.absoluteString) } ?? false }
    }

    /// Forgets a flow's page once its tab handed back (a later tab at the same address is a new flow).
    private func endFlow(first: URL?, requested: URL?) {
        let ended = Set([first, requested].compactMap { $0?.absoluteString })
        flowPages.removeAll { ended.contains($0) }
    }

    /// The app macOS opens a URL with (Launch Services), nil when none does.
    let appFor: @MainActor (URL) -> URL?
    /// The last "no app opens it" notice (``open``).
    private var toldNoApp: (scheme: String, at: Date)?
    var now: () -> Date = Date.init

    init(defaults: UserDefaults = .standard, ownSchemes: Set<String>? = nil,
         appFor: @escaping @MainActor (URL) -> URL? = { NSWorkspace.shared.urlForApplication(toOpen: $0) }) {
        self.defaults = defaults
        self.ownSchemes = ownSchemes ?? Self.schemes(in: Bundle.main.infoDictionary)
        self.appFor = appFor
    }

    /// The URL schemes an Info.plist registers, lowercased.
    static func schemes(in info: [String: Any]?) -> Set<String> {
        let types = info?["CFBundleURLTypes"] as? [[String: Any]] ?? []
        return Set(types.flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] }.map { $0.lowercased() })
    }

    /// Hands a link in this app's own scheme to the app itself. False: not
    /// ours (or no route installed), the caller goes on to Launch Services.
    func openOwn(_ url: URL, from page: URL?, firstPage: URL?, requestedPage: URL? = nil, userGesture: Bool,
                 ask: (BrowserPromptKind, String, @escaping (BrowserPromptResponse) -> Void) -> Void,
                 close: (() -> Void)?) -> Bool {
        guard let scheme = url.scheme?.lowercased(), ownSchemes.contains(scheme), let route = openOwnURL else { return false }
        let flowTab = startedFlow(first: firstPage, requested: requestedPage)
        if isOwnHandoff?(url) == true || (flowTab && isFlowReturn?(url) == true) {
            route(url)
            if flowTab {
                endFlow(first: firstPage, requested: requestedPage)
                close?()
            }
            return true
        }
        let site = userGesture ? page.flatMap(PageInfoSite.origin(of:)) ?? "" : ""
        if canOpenWithoutPrompt(scheme, for: site, engine: .webkit, userGesture: userGesture) {
            route(url)
            return true
        }
        let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "cmux"
        ask(.openExternalApp(app: name, scheme: scheme), site) { [weak self] response in
            switch response {
            case .allow:
                self?.allowAlways(scheme, for: site)
                route(url)
            case .allowOnce:
                route(url)
            default:
                break
            }
        }
        return true
    }

    /// Opens a main-frame link in its app, or asks first through the tab's
    /// prompt bar. Non-gesture navigations always require the app-opening
    /// prompt, including schemes that open immediately from a click.
    /// `firstPage`: the first page of the tab's history; `close` closes the
    /// tab (both for an own-scheme handoff, ``openOwn``).
    func open(_ url: URL, from page: URL?, engine: BrowserEngineKind = .webkit, userGesture: Bool, firstPage: URL? = nil,
              requestedPage: URL? = nil, close: (() -> Void)? = nil,
              ask: (BrowserPromptKind, String, @escaping (BrowserPromptResponse) -> Void) -> Void) {
        if openOwn(url, from: page, firstPage: firstPage, requestedPage: requestedPage, userGesture: userGesture, ask: ask, close: close) { return }
        guard let scheme = url.scheme?.lowercased() else { return }
        guard let app = appFor(url) else {
            // No app opens it. A click on such a link does nothing, as in Chrome; a page that sent the tab
            // there itself (a sign-in's return by redirect or script, ask-2d244f2b2e) is the person's flow
            // ending, so cmux tells them instead of the flow just stopping.
            // A page that retries in a loop is told once per scheme every few seconds.
            if !userGesture, toldNoApp.map({ $0.scheme != scheme || now().timeIntervalSince($0.at) > 5 }) ?? true {
                toldNoApp = (scheme, now())
                ask(.noAppForScheme(scheme: scheme), page.flatMap(PageInfoSite.origin(of:)) ?? "") { _ in }
            }
            return
        }
        // A non-gesture navigation can be a redirect whose source is the
        // previously committed page, so it cannot safely inherit that site's
        // remembered permission. The empty origin also hides "Always allow"
        // for this one-off handoff.
        let site = userGesture ? page.flatMap(PageInfoSite.origin(of:)) ?? "" : ""
        if canOpenWithoutPrompt(scheme, for: site, engine: engine, userGesture: userGesture) {
            return launch(url)
        }
        let name = FileManager.default.displayName(atPath: app.path).replacingOccurrences(of: ".app", with: "")
        ask(.openExternalApp(app: name, scheme: scheme), site) { [weak self] response in
            switch response {
            case .allow:
                self?.allowAlways(scheme, for: site)
                self?.launch(url)
            case .allowOnce:
                self?.launch(url)
            default:
                break
            }
        }
    }

    func canOpenWithoutPrompt(_ scheme: String, for site: String, engine: BrowserEngineKind, userGesture: Bool) -> Bool {
        guard userGesture else { return false }
        if engine == .webkit && Self.wellKnownSchemes.contains(scheme) { return true }
        guard !site.isEmpty else { return false }
        return (defaults.dictionary(forKey: Self.defaultsKey)?[site] as? [String])?.contains(scheme) == true
    }

    private func allowAlways(_ scheme: String, for site: String) {
        guard !site.isEmpty else { return }
        var stored = defaults.dictionary(forKey: Self.defaultsKey) ?? [:]
        let schemes = stored[site] as? [String] ?? []
        guard !schemes.contains(scheme) else { return }
        stored[site] = schemes + [scheme]
        defaults.set(stored, forKey: Self.defaultsKey)
    }

    private func launch(_ url: URL) {
        #if DEBUG
        if records {
            recorded.append(url)
            return
        }
        #endif
        NSWorkspace.shared.openInBackground(url)
    }
}
