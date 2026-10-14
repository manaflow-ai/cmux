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

    typealias PopupRoute = BrowserReplPopupRoute

    /// Routes a window the page in `panelID` opens (``BrowserReplPopupRoute``).
    func popupRoute(panelID: UUID, url: URL?) -> PopupRoute {
        guard let attachment = BrowserReplTabAttachments.shared.attachment(for: panelID),
              attachment.isAttached else { return .browser }
        return BrowserReplPopupRoute(
            url: url,
            openerCreatedBySession: attachment.appliesSessionPolicies,
            creatorPolicy: attachment.creatorSessionID.flatMap { policies[$0] } ?? BrowserReplDomainPolicy(),
            inputSession: attachment.inputSessionID.map { ($0, policies[$0] ?? BrowserReplDomainPolicy()) },
            allowlist: BrowserURLAllowlistPolicy(defaults: .standard)
        )
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

    /// Throws unless the focused frame's own origin matches one of a secret's
    /// domains (`secretDomains` as the session sends them); see
    /// ``BrowserReplSecretTarget``.
    static func checkSecretTarget(
        name: String,
        domains: [[String: Any]],
        webView: WKWebView,
        frames: [BrowserReplFrame]
    ) async throws {
        try await BrowserReplSecretTarget(name: name, domains: domains, world: BrowserReplDriverWorld.world)
            .check(in: webView, frames: frames)
    }
}
