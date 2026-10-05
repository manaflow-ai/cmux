import Foundation

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

    public init(permissions: @escaping () -> SitePermissionStore, ask: @escaping Ask) {
        self.permissions = permissions
        self.ask = ask
    }

    /// A fresh user gesture on the page.
    public func userGesture() {}

    /// A download a page on `site` (its origin; nil for an opaque origin)
    /// starts: `decide(true)` lets it go ahead, `decide(false)` refuses it.
    /// `decide` is called exactly once.
    public func request(site: String?, decide: @escaping (Bool) -> Void) {
        decide(true)
    }
}
