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
    /// Shows the question for `site` and calls `answer` once.
    public typealias Ask = (_ site: String, _ answer: @escaping (BrowserPromptResponse) -> Void) -> Void

    private let permissions: () -> SitePermissionStore
    private let ask: Ask
    private var policy = AutomaticDownloadPolicy()
    /// Downloads waiting for a site's decision (its stored setting, or the
    /// open question): one question per site, one answer for all of them.
    private var waiting: [String: [(Bool) -> Void]] = [:]
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
    /// starts: `decide(true)` lets it go ahead, `decide(false)` refuses it.
    /// `decide` is called exactly once. A later download waits for the
    /// profile's stored decisions to load; an opaque origin is counted
    /// alone and asked every time (nothing to remember it by).
    public func request(site: String?, decide: @escaping (Bool) -> Void) {
        let key = site ?? ""
        guard !policy.countDownload(site: key) else { return decide(true) }
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
                finish(key, allowed: true)
            case .refuse:
                logger.notice("automatic download refused: blocked for \(key, privacy: .private)")
                finish(key, allowed: false)
            case .ask:
                ask(site ?? "") { [self] response in
                    if let site {
                        switch response {
                        case .allow: store.set(.allow, .automaticDownloads, for: site)
                        case .deny: store.set(.block, .automaticDownloads, for: site)
                        default: break
                        }
                    }
                    let allowed = response == .allow || response == .allowOnce
                    if !allowed { logger.notice("automatic download refused by the person for \(key, privacy: .private)") }
                    finish(key, allowed: allowed)
                }
            }
        }
    }

    private func finish(_ key: String, allowed: Bool) {
        for decide in waiting.removeValue(forKey: key) ?? [] { decide(allowed) }
    }
}
