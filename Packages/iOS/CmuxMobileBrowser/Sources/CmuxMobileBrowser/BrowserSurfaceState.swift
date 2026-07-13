public import Foundation
import Observation

/// The observable state of a single phone-local browser pane.
///
/// This is the mobile analogue of a terminal surface, but its lifecycle is
/// entirely local: there is no Mac-side counterpart in P1. The view layer
/// (`MobileBrowserView`) drives this from `WKWebView` callbacks; the address
/// bar reads `addressText`, the chrome reads `canGoBack`/`canGoForward`/
/// `isLoading`/`estimatedProgress`, and a pending ``loadRequest`` tells the
/// representable what URL to load next.
///
/// It is `@MainActor @Observable` (not `ObservableObject`/`@Published`), so
/// SwiftUI tracks individual property reads and the `WKWebView` coordinator can
/// mutate it directly on the main actor.
@MainActor
@Observable
public final class BrowserSurfaceState: Identifiable {
    /// A stable identifier for a browser surface, so SwiftUI can key the hosting
    /// representable and tear down the `WKWebView` when the surface changes.
    public struct ID: RawRepresentable, Hashable, Sendable {
        /// The backing identifier string.
        public var rawValue: String

        /// Creates an identifier from its raw string value.
        /// - Parameter rawValue: The backing identifier.
        public init(rawValue: String) {
            self.rawValue = rawValue
        }
    }

    /// A history/navigation command the chrome can request against the hosted
    /// web view.
    public enum NavigationCommand: Equatable, Sendable {
        /// Navigate back one history entry.
        case goBack
        /// Navigate forward one history entry.
        case goForward
        /// Reload the current page.
        case reload
        /// Stop the in-flight navigation.
        case stopLoading
    }

    /// The surface's stable identifier.
    public let id: ID

    /// The text currently shown in (or being edited in) the address bar. The
    /// view keeps this in sync with the live URL when not editing.
    public var addressText: String

    /// Whether the user is currently editing the address bar. While `true`, the
    /// web view's URL/navigation callbacks must not overwrite ``addressText``,
    /// otherwise a redirect or in-flight URL change clobbers the user's typing.
    public var isAddressEditing: Bool

    /// The page's reported title, or `nil` before the first navigation
    /// resolves a title.
    public var title: String?

    /// The page's current committed URL, or `nil` before the first navigation.
    public var currentURL: URL?

    /// The URL WebKit explicitly committed for the security indicator.
    ///
    /// This is intentionally separate from ``currentURL``. Restored and pending
    /// destinations may seed `currentURL` before the new `WKWebView` commits
    /// them, and must never receive secure or insecure chrome prematurely.
    private(set) var securityIndicatorURL: URL?
    /// The last URL WebKit committed, retained while a provisional navigation
    /// temporarily clears the visible security indicator.
    private var committedSecurityIndicatorURL: URL?

    /// The most recent WebKit interaction state for this surface.
    ///
    /// `WKWebView` instances are view-lifecycle objects and can be torn down
    /// during workspace switches. This snapshot lets a fresh web view restore
    /// the page plus its back/forward list while the in-memory surface
    /// survives. WebKit documents `WKWebView.interactionState` as an opaque
    /// value, so it is held as-is and only ever handed back to WebKit.
    public var savedInteractionState: Any?

    /// The content mode subsequent page loads should request. Starts as
    /// ``BrowserContentModePreference/recommended`` and becomes an explicit mode once
    /// the user toggles the desktop-site menu item.
    public var contentModePreference: BrowserContentModePreference

    /// Whether this device's recommended WebKit content mode is desktop
    /// (true on iPad, false on iPhone). Injected by the hosting view when the
    /// web view attaches, so this package stays UIKit-free and the toggle's
    /// label and first action are correct on iPads, whose default
    /// ``BrowserContentModePreference/recommended`` mode already loads desktop sites.
    public var recommendedContentModeIsDesktop: Bool

    /// Whether subsequent page loads request the desktop site, resolving
    /// ``BrowserContentModePreference/recommended`` to the device default. Drives the
    /// menu label and the toggle direction.
    public var prefersDesktopSite: Bool {
        switch contentModePreference {
        case .recommended: recommendedContentModeIsDesktop
        case .mobile: false
        case .desktop: true
        }
    }

    /// Whether a navigation is in flight. Drives the progress indicator and the
    /// reload/stop button affordance.
    public var isLoading: Bool

    /// The latest navigation progress in `0...1`. Only meaningful while
    /// ``isLoading`` is `true`.
    public var estimatedProgress: Double

    /// Whether the web view can navigate back in its history.
    public var canGoBack: Bool

    /// Whether the web view can navigate forward in its history.
    public var canGoForward: Bool

    /// A user-facing error message for the most recent failed navigation, or
    /// `nil` when the last navigation succeeded or none has occurred.
    public var lastErrorMessage: String?

    /// The destination associated with ``lastErrorMessage``, used by the
    /// recoverable error UI for retry.
    public var lastFailedURL: URL?

    /// Whether the visible failure happened before WebKit committed the failed
    /// destination. The previously committed page remains underneath that error.
    public var lastFailureWasProvisional: Bool

    /// A pending URL the representable should load, set by ``load(_:)``. The
    /// view consumes it via ``consumeLoadRequest()`` and clears it so the same
    /// request is not replayed on re-render.
    public private(set) var loadRequest: URL?

    /// A pending history/navigation command the representable should run against
    /// the `WKWebView` (back, forward, reload, stop). The view consumes it via
    /// ``consumeCommand()`` and clears it so the same command runs once.
    public private(set) var pendingCommand: NavigationCommand?

    /// Invoked after the durable subset of this state changes. The owning
    /// ``BrowserSurfaceStore`` installs this so workspace association and the
    /// last committed page survive a cold app launch.
    private var persistDurableState: (@MainActor (_ immediately: Bool) -> Void)?

    /// Creates a browser surface state.
    ///
    /// - Parameters:
    ///   - id: The surface's stable identifier.
    ///   - initialURL: An optional URL to load when the surface first appears.
    ///     When provided, ``loadRequest`` and ``addressText`` are seeded from it.
    public init(id: ID, initialURL: URL? = nil) {
        self.id = id
        self.addressText = initialURL?.absoluteString ?? ""
        self.isAddressEditing = false
        self.title = nil
        self.currentURL = initialURL
        self.securityIndicatorURL = nil
        self.committedSecurityIndicatorURL = nil
        self.savedInteractionState = nil
        self.contentModePreference = .recommended
        self.recommendedContentModeIsDesktop = false
        self.isLoading = initialURL != nil
        self.estimatedProgress = 0
        self.canGoBack = false
        self.canGoForward = false
        self.lastErrorMessage = nil
        self.lastFailedURL = nil
        self.lastFailureWasProvisional = false
        self.loadRequest = initialURL
        self.persistDurableState = nil
    }

    /// Request a navigation to `url`. Sets ``loadRequest`` for the view to pick
    /// up and seeds the address bar so it reflects the target immediately.
    ///
    /// - Parameter url: The URL to load.
    public func load(_ url: URL) {
        loadRequest = url
        addressText = url.absoluteString
        securityIndicatorURL = nil
        isLoading = true
        estimatedProgress = 0
        lastErrorMessage = nil
        lastFailedURL = nil
        lastFailureWasProvisional = false
        savedInteractionState = nil
    }

    /// Store a new WebKit interaction-state snapshot when WebKit provides one.
    ///
    /// - Parameter interactionState: The opaque `WKWebView.interactionState`
    ///   value, or `nil` when WebKit has no restorable state yet.
    public func saveInteractionState(_ interactionState: Any?) {
        guard let interactionState else { return }
        savedInteractionState = interactionState
    }

    /// Update the content-mode preference and request a reload when a page is
    /// already loaded.
    ///
    /// - Parameter preference: The content mode subsequent loads should request.
    public func setContentModePreference(_ preference: BrowserContentModePreference) {
        guard contentModePreference != preference else { return }
        contentModePreference = preference
        persistDurableState?(true)
        if loadRequest == nil, currentURL != nil {
            request(.reload)
        }
    }

    /// Flip the desktop-site preference relative to the current effective
    /// mode. On iPhone the first toggle forces the desktop site; on iPad
    /// (where ``recommendedContentModeIsDesktop`` is true) it forces the
    /// mobile site. Explicit modes are forced, never the device default, so
    /// the request is honored regardless of device.
    public func togglePrefersDesktopSite() {
        setContentModePreference(prefersDesktopSite ? .mobile : .desktop)
    }

    /// Resolve and load whatever is currently in the address bar, returning
    /// whether a loadable URL was produced.
    ///
    /// - Parameter resolver: The resolver used to interpret the address text.
    ///   Defaults to ``BrowserURLResolver`` semantics.
    /// - Returns: `true` if a URL was resolved and a load was requested.
    @discardableResult
    public func submitAddress(using resolve: (String) -> URL? = { BrowserURLResolver.resolve($0) }) -> Bool {
        guard let url = resolve(addressText) else { return false }
        load(url)
        return true
    }

    /// Consume the pending ``loadRequest``, returning it and clearing it so the
    /// view loads each request exactly once.
    ///
    /// Returns `nil` without mutating when nothing is pending, so the
    /// representable's `updateUIView` (which calls this on every refresh) does
    /// not write observable state on no-op refreshes and trigger a re-render
    /// loop while a page is loading.
    ///
    /// - Returns: The pending load URL, or `nil` if none is pending.
    public func consumeLoadRequest() -> URL? {
        guard let request = loadRequest else { return nil }
        loadRequest = nil
        return request
    }

    /// Request a history/navigation command (back, forward, reload, stop). The
    /// representable runs it against the web view and clears it.
    ///
    /// - Parameter command: The command to run.
    public func request(_ command: NavigationCommand) {
        pendingCommand = command
    }

    /// Consume the pending navigation command, returning it and clearing it so
    /// the view runs each command exactly once.
    ///
    /// Returns `nil` without mutating when nothing is pending, for the same
    /// no-op-refresh reason as ``consumeLoadRequest()``.
    ///
    /// - Returns: The pending command, or `nil` if none is pending.
    public func consumeCommand() -> NavigationCommand? {
        guard let command = pendingCommand else { return nil }
        pendingCommand = nil
        return command
    }

    /// Mark the start of a navigation: loading begins, progress resets, and any
    /// prior error is cleared.
    public func navigationDidStart() {
        isLoading = true
        estimatedProgress = 0
        securityIndicatorURL = nil
        lastErrorMessage = nil
        lastFailedURL = nil
        lastFailureWasProvisional = false
    }

    /// Record the URL from WebKit's explicit navigation-commit callback.
    ///
    /// - Parameter url: The committed WebKit URL, or `nil` when WebKit did not
    ///   expose one for the commit.
    func navigationDidCommit(url: URL?) {
        securityIndicatorURL = url
        committedSecurityIndicatorURL = url
    }

    /// Commit a URL change that WebKit reports without a full navigation
    /// lifecycle, such as `history.pushState` or a fragment change.
    ///
    /// - Parameter url: The page identity currently visible in WebKit.
    func navigationURLDidChange(_ url: URL) {
        guard currentURL != url else { return }
        currentURL = url
        if !isAddressEditing {
            addressText = url.absoluteString
        }
        persistDurableState?(false)
    }

    /// Save a non-empty page title reported outside the navigation lifecycle.
    ///
    /// Single-page apps can update their title after `didFinish`, so KVO title
    /// changes must persist independently of completed navigations.
    /// - Parameter title: The latest page title reported by WebKit.
    func pageTitleDidChange(_ title: String?) {
        let normalizedTitle = title.flatMap { $0.isEmpty ? nil : $0 }
        // WebKit clears `title` while a new page is provisional. Keep the
        // committed title until success so a provisional failure restores it.
        guard normalizedTitle != nil || !isLoading,
              self.title != normalizedTitle else { return }
        self.title = normalizedTitle
        persistDurableState?(false)
    }

    /// Mark a successful navigation finish and save its committed identity.
    ///
    /// - Parameters:
    ///   - url: The URL WebKit committed for the completed navigation.
    ///   - title: The page title WebKit reported, when non-empty.
    public func navigationDidFinish(url: URL? = nil, title: String? = nil) {
        isLoading = false
        estimatedProgress = 1
        securityIndicatorURL = url
        committedSecurityIndicatorURL = url
        if let url {
            currentURL = url
            if !isAddressEditing {
                addressText = url.absoluteString
            }
        }
        self.title = title.flatMap { $0.isEmpty ? nil : $0 }
        lastErrorMessage = nil
        lastFailedURL = nil
        lastFailureWasProvisional = false
        persistDurableState?(true)
    }

    /// Mark a navigation failure with a user-facing message.
    ///
    /// - Parameters:
    ///   - message: The error description to surface in the chrome.
    ///   - url: The failed destination, when known.
    ///   - wasProvisional: Whether WebKit failed before committing the destination.
    public func navigationDidFail(
        message: String,
        url: URL? = nil,
        wasProvisional: Bool = false
    ) {
        isLoading = false
        estimatedProgress = 0
        if wasProvisional {
            securityIndicatorURL = committedSecurityIndicatorURL
        } else {
            securityIndicatorURL = nil
            committedSecurityIndicatorURL = nil
        }
        lastErrorMessage = message
        lastFailedURL = url
        lastFailureWasProvisional = wasProvisional
    }

    /// Restores committed chrome after a cancelled provisional navigation.
    public func navigationDidCancel() {
        isLoading = false
        estimatedProgress = 0
        securityIndicatorURL = committedSecurityIndicatorURL
        if let currentURL, !isAddressEditing {
            addressText = currentURL.absoluteString
        }
    }

    /// Retry the failed destination, if one was recorded.
    public func retryFailedNavigation() {
        guard let lastFailedURL else { return }
        load(lastFailedURL)
    }

    /// Clear a visible navigation error without changing the committed page.
    public func clearNavigationError() {
        if lastFailureWasProvisional, let currentURL, !isAddressEditing {
            addressText = currentURL.absoluteString
        }
        lastErrorMessage = nil
        lastFailedURL = nil
        lastFailureWasProvisional = false
    }

    /// Install the store-owned durable-state callback.
    func installPersistence(_ action: @escaping @MainActor (_ immediately: Bool) -> Void) {
        persistDurableState = action
    }
}
