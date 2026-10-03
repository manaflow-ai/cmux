import CmuxBrowser
import CmuxSettings
import WebKit

/// The driver's own content world. Agent code can run scripts in the agent
/// world (`frame.evaluate` with `world: "agent"`) and pages run in the page
/// world; neither can reach this one, so the checks and masks the driver
/// runs here cannot be patched by them.
enum BrowserReplDriverWorld {
    @MainActor static let world = WKContentWorld.world(name: "cmux-driver")
}

/// Cancels main-frame navigations the domain policy blocks in tabs a REPL
/// session created (a link, a redirect, a script, a popup's first load).
///
/// Tabs the user owns are not navigated away for the policy: the driver
/// refuses the session's reads and input there instead. The navigation
/// delegate asks `cancels(panelID:url:)` for every main-frame navigation.
@MainActor
final class BrowserReplNavigationGuard {
    static let shared = BrowserReplNavigationGuard()

    private var policies: [String: BrowserReplDomainPolicy] = [:]

    func setPolicy(_ policy: BrowserReplDomainPolicy, sessionID: String) {
        policies[sessionID] = policy.isActive ? policy : nil
    }

    func removeSession(_ sessionID: String) {
        policies.removeValue(forKey: sessionID)
    }

    /// Whether the navigation of `panelID` to `url` must be cancelled. A
    /// cancelled navigation is reported to the sessions as `navigation.blocked`.
    func cancels(panelID: UUID, url: URL) -> Bool {
        guard !policies.isEmpty,
              let attachment = BrowserReplTabAttachments.shared.attachment(for: panelID),
              let creator = attachment.creatorSessionID,
              let policy = policies[creator],
              let reason = policy.blockReason(url.absoluteString) else { return false }
        attachment.emit("navigation.blocked", ["url": url.absoluteString, "reason": reason])
        return true
    }

    /// Where a window a page opens goes.
    enum PopupRoute: Equatable {
        /// To the REPL sessions driving the tab, as a new background tab.
        case session
        /// The browser's own popup path, as if no session drove the tab.
        case browser
        /// Nowhere: the window does not open.
        case refused(String)
    }

    /// Routes a window the page in `panelID` opens. The page controls the
    /// URL, and a session's popup opens through cmux's own navigation, which
    /// trusts local files and internal schemes, so it goes to the sessions
    /// only if it passes as an untrusted navigation under the browser's URL
    /// allowlist and the creating session's domain policy. Otherwise a tab a
    /// session created opens nothing, and a user's tab a session only drives
    /// leaves it to the browser.
    func popupRoute(panelID: UUID, url: URL?) -> PopupRoute {
        guard let attachment = BrowserReplTabAttachments.shared.attachment(for: panelID),
              attachment.isAttached else { return .browser }
        let policy = attachment.creatorSessionID.flatMap { policies[$0] } ?? BrowserReplDomainPolicy()
        guard let reason = policy.popupBlockReason(url, allowlist: BrowserURLAllowlistPolicy(defaults: .standard)) else {
            return .session
        }
        return attachment.appliesSessionPolicies ? .refused(reason) : .browser
    }
}

/// Secret input checks, run in the driver's world. Capture masks are
/// `BrowserReplCaptureMask`.
@MainActor
enum BrowserReplSecretGuard {
    /// The origin (`scheme://host[:port]`) of `info`'s frame, from WebKit's
    /// own record of it, never from page script.
    static func origin(of info: WKFrameInfo) -> String? {
        info.browserReplOrigin
    }

    private static let focusProbe = """
    const el = document.activeElement;
    return document.hasFocus() && !!el && el.tagName !== "IFRAME" && el.tagName !== "FRAME";
    """

    /// The frame whose document holds the focused element, which is where
    /// inserted text goes, or nil when no frame answers.
    static func focusedFrame(in webView: WKWebView, frames: [BrowserReplFrame]) async -> BrowserReplFrame? {
        var focused: BrowserReplFrame?
        for frame in frames {
            guard let info = frame.info else { continue }
            let answer = try? await webView.callAsyncJavaScript(
                focusProbe, arguments: [:], in: info, contentWorld: BrowserReplDriverWorld.world
            )
            if answer as? Bool == true { focused = frame }
        }
        return focused
    }

    /// Throws unless the focused frame's own origin matches one of a secret's
    /// domains (`secretDomains` as the session sends them).
    static func checkSecretTarget(
        name: String,
        domains rawDomains: [[String: Any]],
        webView: WKWebView,
        frames: [BrowserReplFrame]
    ) async throws {
        let domains = rawDomains.compactMap(BrowserReplDomainPattern.from(json:))
        guard let frame = await focusedFrame(in: webView, frames: frames), let info = frame.info,
              let origin = origin(of: info) else {
            throw BrowserReplDriverError(code: "invalid", message: "secret \"\(name)\" was not typed: no focused field in the page")
        }
        guard domains.contains(where: { $0.matches(origin: origin, secure: true) }) else {
            let list = domains.map(\.raw).joined(separator: ", ")
            throw BrowserReplDriverError(code: "invalid", message: "secret \"\(name)\" may not be typed into \(origin); its domains are \(list)")
        }
    }
}
