import Foundation

/// The Secure Store login guard (``BrowserLoginGuards``) for agent code that reaches a page outside
/// the control socket's page verbs: the browser host's `frame.evaluate` and cookie writes, and its
/// raw DevTools relay (cmux https://github.com/manaflow-ai/cmux/issues/25830). The app makes one
/// over its one guard, so every path records and refuses the same sites.
public final class BrowserAgentCodeGate: Sendable {
    let guards: BrowserLoginGuards
    let engine: any BrowserPageEngine

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

    /// Before a capture (a screenshot, a PDF) of tab `id`: nil admits it; else why it is refused
    /// (the tab's site holds a filled sign-in).
    public func admitCapture(tabID id: String, url: String?, profile: String?) async -> String? {
        let tab = BrowserPageService.Tab(id: id, url: url, browserProfileID: profile)
        let page = await BrowserPageService.pageOrigin(engine, tab, url: url)
        return await guards.mayCapture(profile: profile, origins: page.origins) ? nil : Self.refusal
    }

    /// Before a raw DevTools relay attaches to tab `id`: nil admits it (marks the site, the tab
    /// never gets a fill, and no tab of the profile gets one while it stays attached); else why
    /// not (the profile holds a filled sign-in: raw DevTools reaches other frames and targets).
    public func admitRaw(tabID id: String, url: String?, profile: String?) async -> String? {
        let tab = BrowserPageService.Tab(id: id, url: url, browserProfileID: profile)
        let page = await BrowserPageService.pageOrigin(engine, tab, url: url)
        return await guards.beginRawDevTools(tab: id, profile: profile, origins: page.origins) ? nil : Self.refusal
    }

    /// The raw DevTools relay of tab `id` ended.
    public func rawEnded(tabID id: String) {
        guards.rawDevToolsEnded(tab: id)
    }

    /// One raw DevTools message on a tab now at `url`, synchronous so the relay keeps message
    /// order: refused while the profile holds any filled sign-in; else the site is marked scripted
    /// at once (persisted after).
    public func rawMessage(url: String?, profile: String?) -> String? {
        guard guards.rawMessageAllowed(profile: profile) else { return Self.refusal }
        if let url, let parsed = URL(string: url), let site = BrowserPageService.webOrigin(parsed),
           guards.noteRawSite(profile: profile, origin: site) {
            let guards = guards
            // task-owner: one actor write per newly reached site; ends when the mark is saved
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
