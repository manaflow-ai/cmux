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
/// // As soon as WebKit asks about a main-frame navigation:
/// let navigation = gate.begin(owner: webView)
/// // When the delegate is ready to decide it, which may be later:
/// gate.admit(navigation, url: request.url) { admitted in
///     decisionHandler(admitted ? .allow : .cancel)
///     return admitted && webView.isLoading && webView.window != nil
/// }
/// // Later, from didStartProvisionalNavigation and the other outcomes:
/// gate.resolve(webView)
/// // When loading is stopped or the web view is closing:
/// gate.abandon(webView)
/// ```
///
/// WebKit drops a navigation that still awaits its decision when its web view
/// starts another or is stopped, and reports nothing. The gate is told of
/// both, so it is the one place that knows whether a navigation may still be
/// allowed: an admission gets `false` for one that is gone.
///
/// ``admit(_:url:admission:)`` takes a callback, not `async`. Taking the gate
/// and telling WebKit to allow the navigation have to be one main-actor step.
/// A continuation would resume its caller in a later job, and until then the
/// web view would hold the gate for a navigation WebKit has not been told to
/// allow. If the web view reported an outcome in that gap, say an earlier
/// load of its committing, the gate would go to the next web view and both
/// navigations would then be allowed.
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
    ///   replaced since WebKit asked about it, so it must be cancelled.
    /// - Returns: Whether the owner will report this navigation's outcome
    ///   through ``resolve(_:)``. The gate stays with the owner only if it
    ///   will; otherwise the next owner is admitted at once.
    public typealias Admission = @MainActor (_ admitted: Bool) -> Bool

    /// A main-frame navigation WebKit has asked about and that is not decided yet.
    ///
    /// Only its identity matters: ``begin(owner:)`` hands one out and
    /// ``admit(_:url:admission:)`` takes it back.
    @MainActor
    public final class UndecidedNavigation {
        fileprivate weak var owner: AnyObject?

        fileprivate init(owner: AnyObject) {
            self.owner = owner
        }
    }

    private struct WeakNavigation {
        weak var navigation: UndecidedNavigation?
    }

    private struct Waiter {
        weak var owner: AnyObject?
        let admission: Admission
    }

    private let isSingleSignOnURL: @MainActor (URL) -> Bool
    // Weak, so a web view that went away without reporting an outcome no longer
    // blocks the next navigation that asks.
    private weak var holder: AnyObject?
    private var isHeld = false
    // Tells one hold from a later one by the same owner.
    private var holdCount = 0
    // The navigations asked about that have not reached `admit`. Weak, so one
    // the delegate decided without the gate drops out by itself.
    private var undecided: [WeakNavigation] = []
    // `begin` drops an owner's earlier entry from both lists, so each holds at
    // most one entry per web view with a navigation awaiting its decision.
    // Scanning them and removing from the front of this one stay cheap.
    private var waiters: [Waiter] = []

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

    /// Records that WebKit asked about a main-frame navigation of the owner.
    ///
    /// Call it for every such navigation, whether or not it goes on to
    /// ``admit(_:url:admission:)``: the navigation the owner was asked about
    /// before is gone. If that one was waiting its turn it is cancelled now;
    /// if it has not reached the gate yet it is cancelled when it does.
    ///
    /// - Parameter owner: The web view the navigation belongs to. Held weakly.
    /// - Returns: The navigation, to pass to ``admit(_:url:admission:)``.
    public func begin(owner: AnyObject) -> UndecidedNavigation {
        cancelWaiters(of: owner)
        undecided.removeAll { entry in
            guard let entryOwner = entry.navigation?.owner else { return true }
            return entryOwner === owner
        }
        let navigation = UndecidedNavigation(owner: owner)
        undecided.append(WeakNavigation(navigation: navigation))
        return navigation
    }

    /// Runs `admission` now, or once every earlier owner's navigation has an outcome.
    ///
    /// A navigation that is gone is cancelled: its owner was asked about a
    /// newer one or was abandoned since ``begin(owner:)``, or it was already
    /// decided. A URL no extension takes is admitted at once and never holds
    /// the gate. So is a navigation of the owner that already holds it: an
    /// extension that handled a navigation answers by loading its result into
    /// the same web view.
    ///
    /// - Parameters:
    ///   - navigation: The navigation ``begin(owner:)`` returned.
    ///   - url: The destination of the navigation.
    ///   - admission: Called at most once with the decision to apply, and
    ///     not at all while the owner keeps waiting.
    public func admit(_ navigation: UndecidedNavigation, url: URL?, admission: @escaping Admission) {
        guard let owner = navigation.owner,
              let index = undecided.firstIndex(where: { $0.navigation === navigation }) else {
            _ = admission(false)
            return
        }
        // From here the navigation is in the queue, or decided.
        undecided.remove(at: index)
        guard let url,
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              isSingleSignOnURL(url) else {
            _ = admission(true)
            return
        }
        releaseIfHolderIsGone()
        let waiter = Waiter(owner: owner, admission: admission)
        if isHeld, holder !== owner {
            waiters.append(waiter)
            return
        }
        hold(waiter)
        admitWaitersWhileFree()
    }

    /// Records that the owner's navigation has an outcome: it started
    /// loading, committed, failed or stopped.
    ///
    /// - Parameter owner: The web view that reported the outcome. Ignored
    ///   unless it holds the gate.
    public func resolve(_ owner: AnyObject) {
        guard isHeld, holder === owner else { return }
        release()
        admitWaitersWhileFree()
    }

    /// Cancels the owner's undecided navigation and frees the gate if it holds it.
    ///
    /// - Parameter owner: A web view whose navigation was given up: it was
    ///   stopped, lost its content process, or is being closed or replaced.
    public func abandon(_ owner: AnyObject) {
        undecided.removeAll { $0.navigation?.owner === owner }
        cancelWaiters(of: owner)
        resolve(owner)
    }

    private func cancelWaiters(of owner: AnyObject) {
        let cancelled = waiters.filter { $0.owner === owner }
        guard !cancelled.isEmpty else { return }
        waiters.removeAll { $0.owner === owner }
        for waiter in cancelled {
            _ = waiter.admission(false)
        }
    }

    private func hold(_ waiter: Waiter) {
        guard let owner = waiter.owner else {
            _ = waiter.admission(false)
            return
        }
        // Set before the call: allowing a navigation may report its outcome re-entrantly.
        holder = owner
        isHeld = true
        holdCount &+= 1
        let ownHold = holdCount
        // The call may also have freed the gate and taken it again, even for
        // the same owner. That newer hold is not this admission's to free.
        if !waiter.admission(true), ownHold == holdCount {
            release()
        }
    }

    private func release() {
        holder = nil
        isHeld = false
    }

    private func releaseIfHolderIsGone() {
        guard isHeld, holder == nil else { return }
        release()
        admitWaitersWhileFree()
    }

    private func admitWaitersWhileFree() {
        while !isHeld, !waiters.isEmpty {
            hold(waiters.removeFirst())
        }
    }
}
