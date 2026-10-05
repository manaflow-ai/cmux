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

extension BrowserReplPolicyBoard {
    /// The board the drivers publish to and the navigation checks read.
    static let shared = BrowserReplPolicyBoard()
}

/// Cancels main-frame navigations the domain policy blocks in tabs a REPL
/// session created (a link, a redirect, a script, a popup's first load),
/// and holds every navigation of such a tab while the session's content
/// rules for its latest policy compile.
///
/// Tabs the user owns are not navigated away for the policy: the driver
/// refuses the session's reads and input there instead. The navigation
/// delegate asks `hold(panelID:)` and `cancels(panelID:url:)` for every
/// navigation. Policies come from ``BrowserReplPolicyBoard``, where the
/// driver publishes each one before its policy setter returns.
@MainActor
final class BrowserReplNavigationGuard {
    static let shared = BrowserReplNavigationGuard()

    private var board: BrowserReplPolicyBoard { .shared }

    /// Whether the navigation of `panelID` to `url` must be cancelled. A
    /// cancelled navigation is reported to the sessions as `navigation.blocked`.
    /// `initiator` is the document that started it (WebKit's record of the
    /// source frame): an `about:blank`, `data:` or opaque `blob:` document
    /// takes or is written by it (``BrowserReplDomainPolicy/navigationBlockReason(_:initiator:)``).
    func cancels(panelID: UUID, url: URL, initiator: BrowserReplFrameDocument?) -> Bool {
        guard let attachment = BrowserReplTabAttachments.shared.attachment(for: panelID),
              let creator = attachment.creatorSessionID,
              let policy = board.policy(for: creator),
              let reason = policy.navigationBlockReason(url, initiator: initiator) else { return false }
        attachment.emit(.navigationBlocked, ["url": attachment.pageURL(url.absoluteString), "reason": reason])
        return true
    }

    /// Whether a navigation of any frame of `panelID`, a tab a session
    /// created (or a popup of one), to the local file `url` must be
    /// cancelled: only files inside the creating session's working and
    /// temporary directories load there, by the rule its own navigations
    /// follow (``BrowserReplFileSandbox/navigationRefusal(_:roots:)``),
    /// whoever started it (a page, a redirect, history). Reported to the
    /// sessions as `navigation.blocked`.
    func cancelsLocalFile(panelID: UUID, url: URL) -> Bool {
        guard url.scheme?.lowercased() == "file",
              let attachment = BrowserReplTabAttachments.shared.attachment(for: panelID),
              let creator = attachment.creatorSessionID,
              let reason = BrowserReplFileSandbox.navigationRefusal(url.absoluteString, roots: board.fileRoots(for: creator) ?? []) else {
            return false
        }
        attachment.emit(.navigationBlocked, ["url": attachment.pageURL(url.absoluteString), "reason": reason])
        return true
    }

    /// What a navigation of `panelID` waits for before it is judged.
    enum Hold {
        /// Judge it now.
        case none
        /// The creating session's content rules for its latest policy are
        /// compiling; a page loaded now would load its subresources under
        /// the previous rules. Judge it once they settle.
        case untilRulesSettle(sessionID: String)
        /// WebKit refused the creating session's content rules, so its
        /// policy is not in force for subresources: refuse the navigation.
        case refused(String)
    }

    /// Whether a navigation (of any frame) of `panelID`, a tab a session
    /// created, to `url` waits or is refused for the session's content rules.
    func hold(panelID: UUID, url: URL?) -> Hold {
        guard let attachment = BrowserReplTabAttachments.shared.attachment(for: panelID),
              let creator = attachment.creatorSessionID else { return .none }
        switch board.ruleState(for: creator) {
        case .installed:
            return .none
        case .pending:
            return .untilRulesSettle(sessionID: creator)
        case .failed(let error):
            let reason = "the domain policy could not be applied (\(error)); set a policy that compiles"
            attachment.emit(.navigationBlocked, ["url": attachment.pageURL(url?.absoluteString ?? ""), "reason": reason])
            return .refused(reason)
        }
    }

    /// Runs `body` once `sessionID`'s content rules settle.
    func whenRulesSettle(sessionID: String, _ body: @escaping @MainActor () -> Void) {
        board.whenRulesSettle(sessionID: sessionID) { _ in body() }
    }

    /// Whether `action`, a navigation or window of `panelID`, may go to the
    /// user's configured external browser instead of loading in the tab
    /// (``BrowserReplTabOwnership/handsLinkToExternalBrowser(_:now:)``):
    /// always for a tab no session drives. In a tab a session drives, the
    /// page's own link activations (`a.click()`, agent-world code) and those
    /// a session's input set off load in the tab under its guards; only one
    /// WebKit marks as the user's gesture (`_isUserInitiated`, read as false
    /// where WebKit cannot say) leaves it. Both the navigation delegate and
    /// the window delegate ask this one decision.
    func handsLinkToExternalBrowser(panelID: UUID, action: WKNavigationAction) -> Bool {
        guard let attachment = BrowserReplTabAttachments.shared.attachment(for: panelID) else { return true }
        return attachment.handsLinkToExternalBrowser(isUserInitiated: action.browserReplIsUserInitiated)
    }

    typealias PopupRoute = BrowserReplPopupRoute

    /// Routes a window the page in `panelID` opens (``BrowserReplPopupRoute``).
    /// `opener` is the document of the frame that opened it; an
    /// `about:blank` window takes its origin.
    func popupRoute(panelID: UUID, url: URL?, opener: BrowserReplFrameDocument?) -> PopupRoute {
        guard let attachment = BrowserReplTabAttachments.shared.attachment(for: panelID),
              attachment.isAttached else { return .browser }
        return BrowserReplPopupRoute(
            url: url,
            openerCreatedBySession: attachment.appliesSessionPolicies,
            creatorPolicy: attachment.creatorSessionID.flatMap { board.policy(for: $0) } ?? BrowserReplDomainPolicy(),
            inputSession: attachment.inputSessionID.map { ($0, board.policy(for: $0) ?? BrowserReplDomainPolicy()) },
            allowlist: BrowserURLAllowlistPolicy(defaults: .standard),
            opener: opener
        )
    }
}

extension WKNavigationAction {
    /// Whether WebKit marks the navigation as started by a user gesture
    /// (`-[WKNavigationAction _isUserInitiated]`); false where WebKit does
    /// not say, so an unknown activation is never taken for the user's.
    @MainActor
    var browserReplIsUserInitiated: Bool {
        let selector = NSSelectorFromString("_isUserInitiated")
        guard responds(to: selector) else { return false }
        return (value(forKey: "_isUserInitiated") as? Bool) ?? false
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
