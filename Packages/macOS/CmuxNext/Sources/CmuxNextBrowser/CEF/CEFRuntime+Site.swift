import CmuxNextDesign
import Foundation

/// A shim reply to an async site call.
nonisolated struct CEFSiteReply: Sendable, Equatable {
    var value: Int64
    var json: String
}

/// Page Info's view of Chromium's own site state (shim ABI 3): content
/// settings of the tab's request context, its cookie manager, and the
/// visible entry's SSL status. All main thread (the CEF UI thread).
extension CEFRuntime {
    /// Longest wait for a cookie visit or delete.
    static let siteReplyTimeout: Duration = .seconds(5)

    /// Chromium's effective value for `kind` on `url`; nil url asks for the
    /// profile default. Nil when the browser is gone or the kind is unknown.
    func contentSetting(_ browser: Int32, url: String?, kind: SitePermissionKind) -> CEFContentSetting? {
        guard let shim else { return nil }
        let raw = shim.contentSetting(browser, url, kind.rawValue)
        return raw < 0 ? nil : CEFContentSetting(rawValue: raw)
    }

    /// Stores `value` for `kind` on `url` (`.default` clears the exception);
    /// url "" sets the profile default.
    @discardableResult
    func setContentSetting(_ browser: Int32, url: String, kind: SitePermissionKind, value: CEFContentSetting) -> Bool {
        shim?.setContentSetting(browser, url, kind.rawValue, value.rawValue) == 1
    }

    /// Every cookie of the tab's profile.
    func cookies(_ browser: Int32) async throws -> [CEFCookie] {
        let reply = try await siteCall(browser, what: "cookie visit") { shim, id in shim.visitCookies(browser, id) }
        return CEFCookie.parse(reply.json)
    }

    /// Deletes the cookies of `url`'s host and domain named `name` (all
    /// names when nil); returns the deleted count.
    @discardableResult
    func deleteCookies(_ browser: Int32, url: String, name: String?) async throws -> Int {
        let reply = try await siteCall(browser, what: "cookie delete") { shim, id in shim.deleteCookies(browser, id, url, name) }
        return Int(reply.value)
    }

    /// The visible navigation entry's SSL status, nil for none.
    func sslStatus(_ browser: Int32) -> CEFSSLStatus? {
        guard let shim, let json = shim.takeOwnedString(shim.sslStatus(browser)) else { return nil }
        return CEFSSLStatus.parse(json)
    }

    /// Forgets every certificate error the user proceeded past in the tab's
    /// profile (CEF has no per-host call) and closes the profile's
    /// connections, so the next load verifies the server again. False when
    /// the shim could not do it.
    func clearCertificateExceptions(_ browser: Int32) async -> Bool {
        let reply = try? await siteCall(browser, what: "certificate exceptions clear") { shim, id in
            shim.clearCertificateExceptions(browser, id)
        }
        return reply?.value == 1
    }

    private func siteCall(_ browser: Int32, what: String,
                          start: (CEFShimLibrary, Int32) -> Int32) async throws -> CEFSiteReply {
        guard let shim else { throw BrowserTabError.closed }
        let id = nextSiteReply
        nextSiteReply = nextSiteReply == .max ? 1 : nextSiteReply + 1
        siteReplyBrowsers[id] = browser
        defer {
            siteReplyBrowsers[id] = nil
            earlySiteReplies[id] = nil
        }
        guard start(shim, id) == 1 else { throw BrowserTabError.closed }
        // CEF may answer before this task awaits (no cookies at all).
        if let early = earlySiteReplies[id] { return early }
        let timeout = Self.siteReplyTimeout
        return try await siteReplies.reply(for: id, timeout: timeout) {
            BrowserTabError.timedOut("CEF \(what) (\(timeout))")
        }
    }
}

extension CEFRuntime: ThemeResponsive {
    /// The Ghostty theme changed: Chromium's process default follows it.
    /// Each attached tab owns its background, set from its view's theme
    /// scope (`CEFTab.pageThemeDidChange`), so this reaches only browsers
    /// still being created (fork API 12; the shim skips an unchanged color).
    func themeDidChange() {
        guard state == .ready else { return }
        shim?.setBackgroundColor(PageBackground.appThemeARGB)
    }
}
