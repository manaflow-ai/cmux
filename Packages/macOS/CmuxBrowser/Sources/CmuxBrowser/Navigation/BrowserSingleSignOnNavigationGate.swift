import AuthenticationServices
public import Foundation

/// Lets one web view at a time take a main-frame navigation to an Extensible SSO URL.
///
/// WebKit hands a navigation to a URL that a macOS Extensible Single Sign-On
/// extension has registered (Microsoft Company Portal, for one) to that
/// extension once the navigation delegate allows it, and it keeps one such
/// authorization per website data store.
/// A second navigation allowed while the first is still with the extension
/// replaces it: WebKit drops the first navigation with no delegate callback,
/// and on macOS 27.2 the second as well, so the tabs are left on an empty
/// document. Holding the second decision until the first navigation has an
/// outcome avoids that, for navigations whose outcome the owner can observe:
/// one it cannot (its admission returns `false`) does not keep the others
/// waiting, and can still be replaced by the next. The wait has no time limit:
/// while an extension keeps a navigation, for instance behind a prompt, the
/// others on that store wait until it answers or the web view is stopped or
/// closed.
///
/// Each website data store carries its own gate
/// (`WKWebsiteDataStore.singleSignOnNavigationGate`), and the navigation
/// delegates of the web views on that store share it:
///
/// ```swift
/// let gate = webView.configuration.websiteDataStore.singleSignOnNavigationGate
/// gate.admit(url: request.url, owner: webView) { admitted in
///     decisionHandler(admitted ? .allow : .cancel)
///     return admitted && webView.isLoading && webView.window != nil
/// }
/// // Later, from didStartProvisionalNavigation and the other outcomes:
/// gate.resolve(webView)
/// ```
///
/// ``admit(url:owner:admission:)`` takes a callback, not `async`: the
/// decision has to be applied in the same main-actor turn in which the gate
/// hands it out, or the web view could be stopped or closed in between.
///
/// A test passes its own check instead of asking macOS:
///
/// ```swift
/// let gate = BrowserSingleSignOnNavigationGate { $0.host == "login.example.com" }
/// ```
@MainActor
public final class BrowserSingleSignOnNavigationGate {
    /// Decides one navigation once the gate reaches it.
    ///
    /// - Parameter admitted: `false` when the navigation was given up or
    ///   replaced while it waited, so it must be cancelled.
    /// - Returns: Whether the owner will report this navigation's outcome
    ///   through ``resolve(_:)``. The gate stays with the owner only if it
    ///   will; otherwise the next owner is admitted at once.
    public typealias Admission = @MainActor (_ admitted: Bool) -> Bool

    private let isSingleSignOnURL: @MainActor (URL) -> Bool

    /// Creates a gate that asks macOS which URLs an Extensible SSO extension
    /// has registered.
    public convenience init() {
        self.init { ASAuthorizationSingleSignOnProvider(identityProvider: $0).canPerformAuthorization }
    }

    /// Creates a gate with its own notion of which URLs an extension takes.
    ///
    /// - Parameter isSingleSignOnURL: Whether an Extensible SSO extension
    ///   would take a navigation to the URL. Only asked about `http` and
    ///   `https` URLs.
    public init(isSingleSignOnURL: @escaping @MainActor (URL) -> Bool) {
        self.isSingleSignOnURL = isSingleSignOnURL
    }

    /// Runs `admission` now, or once every earlier owner's navigation has an outcome.
    ///
    /// A URL no extension takes is admitted at once and never holds the gate.
    /// So is a navigation of the owner that already holds it: an extension
    /// that handled a navigation answers by loading its result into the same
    /// web view. A newer navigation from an owner that is still waiting,
    /// whatever its URL, cancels the older: the web view has moved on.
    ///
    /// - Parameters:
    ///   - url: The destination of the main-frame navigation.
    ///   - owner: The web view the navigation belongs to. Held weakly.
    ///   - admission: Called at most once with the decision to apply, and
    ///     not at all while the owner keeps waiting.
    public func admit(url: URL?, owner: AnyObject, admission: @escaping Admission) {
        _ = admission(true)
    }

    /// Records that the owner's navigation has an outcome: it started
    /// loading, committed, failed or stopped.
    ///
    /// - Parameter owner: The web view that reported the outcome. Ignored
    ///   unless it holds the gate.
    public func resolve(_ owner: AnyObject) {}

    /// Cancels the owner's waiting navigation and frees the gate if it holds it.
    ///
    /// - Parameter owner: A web view whose navigation was given up: it was
    ///   stopped, lost its content process, or is being closed or replaced.
    public func abandon(_ owner: AnyObject) {}
}
