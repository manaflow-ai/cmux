import Foundation
import os

/// One tab's automatic downloads: both engines call `request` before a
/// download the page started goes ahead and `userGesture` on user input.
/// The decision is `AutomaticDownloadPolicy`'s; the remembered answers
/// live in the profile's `SitePermissionStore` (`automaticDownloads`), so
/// Page Info and Site settings show and edit them, a private profile keeps
/// them in memory only, and a decision made in one engine holds in the
/// other.
public final class AutomaticDownloadGate {
    /// Shows the question for `site` and calls `answer` once. Returns false
    /// when the question cannot show (the tab is closed or in no window);
    /// `answer` is then never called.
    public typealias Ask = (_ site: String, _ answer: @escaping (BrowserPromptResponse) -> Void) -> Bool

    /// What happens to one download.
    public enum Outcome: Equatable, Sendable {
        case allowed
        /// The site is blocked (a remembered Block): refused and listed as
        /// blocked, with the site's settings to change the choice.
        case refused
        /// The person answered Block for the downloads held by the
        /// question: refused and listed as blocked.
        case declined
        /// No answer was possible (the question could not show, or the tab
        /// closed with it open): refused and listed as blocked, never held.
        case unanswered
    }

    private let permissions: () -> SitePermissionStore
    private let ask: Ask
    private var policy = AutomaticDownloadPolicy()
    /// Downloads waiting for a site's decision (its stored setting, or the
    /// open question): one question per site, one answer for all of them.
    private var waiting: [String: [(Outcome) -> Void]] = [:]
    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "browser.downloads")

    public init(permissions: @escaping () -> SitePermissionStore, ask: @escaping Ask) {
        self.permissions = permissions
        self.ask = ask
    }

    /// A fresh user gesture on the page. A gesture while a decision is
    /// pending does not reset the count (Chrome: clicking around the open
    /// question is not an answer).
    public func userGesture() {
        guard waiting.isEmpty else { return }
        policy.userGesture()
    }

    /// A download a page on `site` (its origin; nil for an opaque origin)
    /// starts: `decide` gets the outcome, exactly once. A later download waits for the
    /// profile's stored decisions to load; an opaque origin is counted
    /// alone and asked every time (nothing to remember it by).
    public func request(site: String?, decide: @escaping (Outcome) -> Void) {
        let key = site ?? ""
        guard !policy.countDownload(site: key) else { return decide(.allowed) }
        if waiting[key] != nil {
            waiting[key]?.append(decide)
            return
        }
        waiting[key] = [decide]
        let store = permissions()
        // Strong self: every waiting `decide` must be called (WebKit's
        // decision handlers must not be dropped); the load is short.
        Task { [self] in
            await store.whenLoaded()
            let setting = site.map { store.setting(.automaticDownloads, for: $0) } ?? .ask
            switch AutomaticDownloadPolicy.decision(isFirst: false, setting: setting) {
            case .allow:
                finish(key, .allowed)
            case .refuse:
                finish(key, .refused)
            case .ask:
                let shown = ask(site ?? "") { [self] response in
                    if let site {
                        switch response {
                        case .allow: store.set(.allow, .automaticDownloads, for: site)
                        case .deny: store.set(.block, .automaticDownloads, for: site)
                        default: break
                        }
                    }
                    finish(key, Self.outcome(of: response))
                }
                if !shown {
                    finish(key, .unanswered)
                }
            }
        }
    }

    /// Allow (or this time) lets the downloads go; Block declines them; a
    /// dismissal (the tab closed with the question open) has no answer.
    static func outcome(of response: BrowserPromptResponse) -> Outcome {
        switch response {
        case .allow, .allowOnce: .allowed
        case .deny: .declined
        default: .unanswered
        }
    }

    /// Why a download with `outcome` is listed blocked (localized); nil
    /// for one that goes ahead. No refusal is silent.
    public static func blockedReason(_ outcome: Outcome) -> String? {
        switch outcome {
        case .allowed: nil
        case .refused: Strings.downloadBlockedBySite
        case .declined: Strings.downloadBlockedDeclined
        case .unanswered: Strings.downloadBlockedUnanswered
        }
    }

    private func finish(_ key: String, _ outcome: Outcome) {
        if outcome != .allowed { logger.notice("automatic download \(String(describing: outcome), privacy: .public) for \(key, privacy: .private)") }
        for decide in waiting.removeValue(forKey: key) ?? [] { decide(outcome) }
    }
}
