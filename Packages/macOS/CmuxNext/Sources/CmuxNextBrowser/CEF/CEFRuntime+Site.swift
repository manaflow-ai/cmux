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
    /// In host mode the host answers in a REPLY (task 018).
    func contentSetting(_ browser: Int32, url: String?, kind: SitePermissionKind) async -> CEFContentSetting? {
        await contentSettings(browser, [(url, kind)])[0]
    }

    /// ``contentSetting(_:url:kind:)`` for each query, in order: every read is sent in this turn and
    /// the answers are awaited after, so in host mode they cost one round trip, not one each.
    func contentSettings(_ browser: Int32, _ queries: [(url: String?, kind: SitePermissionKind)]) async -> [CEFContentSetting?] {
        let sent = queries.map { sendContentSetting(browser, url: $0.url, kind: $0.kind) }
        var values: [CEFContentSetting?] = []
        for pending in sent { values.append(Self.contentSetting(try? await answer(pending, label: "content setting"))) }
        return values
    }

    /// ``contentSetting(_:url:kind:)`` for a synchronous turn: `then` runs with
    /// the value in this turn in process, when the host's REPLY comes in host mode.
    func contentSetting(_ browser: Int32, url: String?, kind: SitePermissionKind, then: @escaping (CEFContentSetting?) -> Void) {
        whenAnswered(sendContentSetting(browser, url: url, kind: kind), label: "content setting") { then(Self.contentSetting($0)) }
    }

    private func sendContentSetting(_ browser: Int32, url: String?, kind: SitePermissionKind) -> CEFShimAnswer<Int32> {
        sendAsync { shim in shim.contentSetting(browser, url, kind.rawValue) }
    }

    private static func contentSetting(_ raw: Int32?) -> CEFContentSetting? {
        guard let raw, raw >= 0 else { return nil }
        return CEFContentSetting(rawValue: raw)
    }

    /// Stores `value` for `kind` on `url` (`.default` clears the exception);
    /// url "" sets the profile default. A post: Page Info reads the value
    /// again with ``contentSetting(_:url:kind:)``.
    func setContentSetting(_ browser: Int32, url: String, kind: SitePermissionKind, value: CEFContentSetting) {
        _ = shim?.setContentSetting(browser, url, kind.rawValue, value.rawValue)
    }

    /// Answers a waiting PERMISSION_PROMPT (`CEFPermissionPrompts`).
    func permissionContinue(_ token: Int32, _ outcome: SitePermissionRequest.Outcome) {
        _ = shim?.permissionContinue(token, outcome == .grant ? 1 : outcome == .deny ? 2 : 0)
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

    /// The visible navigation entry's SSL status, nil for none. Read on
    /// demand: no event reports its changes (chromium-host-ops.json), so in
    /// host mode the host answers in a REPLY (task 018).
    func sslStatus(_ browser: Int32) async -> CEFSSLStatus? {
        // try? flattens the String? answer: nil for no answer and for a NULL status alike.
        (try? await answer(sendSSLStatus(browser), label: "SSL status")).flatMap(CEFSSLStatus.parse)
    }

    /// ``sslStatus(_:)`` for a synchronous turn (a load event): `then` runs in
    /// this turn in process, when the host's REPLY comes in host mode.
    func sslStatus(_ browser: Int32, then: @escaping (CEFSSLStatus?) -> Void) {
        whenAnswered(sendSSLStatus(browser), label: "SSL status") { json in then(json.flatMap { $0 }.flatMap(CEFSSLStatus.parse)) }
    }

    private func sendSSLStatus(_ browser: Int32) -> CEFShimAnswer<String?> {
        sendAsync { shim in shim.sslStatus(browser) }
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

    /// Starts an op that a CMUX_SHIM_REPLY event answers under a fresh reply
    /// id (`start` gets the shim and the id), then awaits that event. A start
    /// result other than 1 fails it (in host mode that result is a REPLY).
    func siteCall(_ browser: Int32, what: String,
                  start: (CEFShimLibrary, Int32) -> Int32) async throws -> CEFSiteReply {
        guard shim != nil else { throw BrowserTabError.closed }
        let id = nextSiteReply
        nextSiteReply = nextSiteReply == .max ? 1 : nextSiteReply + 1
        siteReplyBrowsers[id] = browser
        defer {
            siteReplyBrowsers[id] = nil
            earlySiteReplies[id] = nil
        }
        let timeout = Self.siteReplyTimeout
        // In host mode the start result is the host's REPLY: a refusal fails here, not at the
        // deadline. The site reply that may come meanwhile waits in earlySiteReplies.
        guard try await answer(sendAsync { start($0, id) }, label: "CEF \(what)", timeout: timeout) == 1 else {
            throw BrowserTabError.closed
        }
        // CEF may answer before this task awaits (no cookies at all).
        if let early = earlySiteReplies[id] { return early }
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
