import CmuxNextCompat
import Foundation

/// The Secure Store login guard (``BrowserLoginGuards``) for agent code that reaches a page outside
/// the control socket's page verbs: the browser host's `frame.evaluate` and cookie writes, and its
/// raw DevTools relay (cmux https://github.com/manaflow-ai/cmux/issues/25830). The app makes one
/// over its one guard, so every path records and refuses the same sites.
public final class BrowserAgentCodeGate: Sendable {
    let guards: BrowserLoginGuards
    let engine: any BrowserPageEngine
    /// Sites the raw relay already marked scripted, so a busy relay sends one mark per site.
    private let rawMarked = Mutex<Set<String>>([])

    /// - Parameters:
    ///   - guards: the app's one login guard.
    ///   - engine: runs the isolated origin probe on a tab.
    public init(guards: BrowserLoginGuards, engine: any BrowserPageEngine) {
        self.guards = guards
        self.engine = engine
    }

    /// Before agent code on tab `id` (showing `url` in `profile`): nil admits it and marks the
    /// site; else why it is refused.
    public func admit(tabID id: String, url: String?, profile: String?) async -> String? {
        let tab = BrowserPageService.Tab(id: id, url: url, browserProfileID: profile)
        let page = await BrowserPageService.pageOrigin(engine, tab, url: url)
        return await guards.beginScript(profile: profile, origins: page.origins) ? nil : Self.refusal
    }

    /// After agent code ran on tab `id`: the site it is on now is marked too.
    public func ran(tabID id: String, url: String?, profile: String?) async {
        let tab = BrowserPageService.Tab(id: id, url: url, browserProfileID: profile)
        await guards.markScripted(profile: profile, origins: BrowserPageService.pageOrigin(engine, tab, url: url).origins)
    }

    /// Before a raw DevTools relay attaches to tab `id`: nil admits it (marks the site, and the
    /// tab never gets a fill); else why not.
    public func admitRaw(tabID id: String, url: String?, profile: String?) async -> String? {
        let tab = BrowserPageService.Tab(id: id, url: url, browserProfileID: profile)
        let page = await BrowserPageService.pageOrigin(engine, tab, url: url)
        return await guards.beginRawDevTools(tab: id, profile: profile, origins: page.origins) ? nil : Self.refusal
    }

    /// One raw DevTools message on a tab now at `url`, synchronous so the relay keeps message
    /// order: nil sends it (the site is marked scripted); else why it is refused.
    public func rawMessage(url: String?, profile: String?) -> String? {
        // An unreadable URL is an unknown site: refused while the profile holds any filled sign-in.
        guard let url, let parsed = URL(string: url) else {
            return guards.rawMessageAllowed(profile: profile, origin: nil) ? nil : Self.refusal
        }
        // A page with no site (about:blank, data:) holds no sign-in.
        guard let site = BrowserPageService.webOrigin(parsed) else { return nil }
        guard guards.rawMessageAllowed(profile: profile, origin: site) else { return Self.refusal }
        let key = BrowserLoginGuards.key(profile: profile, origin: site)
        if rawMarked.withLock({ $0.insert(key).inserted }) {
            let guards = guards
            Task { await guards.markScripted(profile: profile, origins: [site]) }
        }
        return nil
    }

    /// A page opened tab `id` (a popup): it never gets a fill.
    public func openedByPage(tabID id: String) async {
        await guards.markOpenedByPage(tab: id)
    }

    static var refusal: String {
        ControlStrings.text("control.error.loginFilled", "This site holds a filled sign-in; agent scripts cannot run on it")
    }
}
