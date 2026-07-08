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

    /// The most recent WebKit interaction state for this surface.
    ///
    /// `WKWebView` instances are view-lifecycle objects and can be torn down
    /// during workspace switches. This data lets a fresh web view restore the
    /// page plus its back/forward list while the in-memory surface survives.
    public var savedInteractionState: Data?

    /// Whether subsequent page loads should request the desktop site.
    public var prefersDesktopSite: Bool

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

    /// A pending URL the representable should load, set by ``load(_:)``. The
    /// view consumes it via ``consumeLoadRequest()`` and clears it so the same
    /// request is not replayed on re-render.
    public private(set) var loadRequest: URL?

    /// A pending history/navigation command the representable should run against
    /// the `WKWebView` (back, forward, reload, stop). The view consumes it via
    /// ``consumeCommand()`` and clears it so the same command runs once.
    public private(set) var pendingCommand: NavigationCommand?

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
        self.savedInteractionState = nil
        self.prefersDesktopSite = false
        self.isLoading = false
        self.estimatedProgress = 0
        self.canGoBack = false
        self.canGoForward = false
        self.lastErrorMessage = nil
        self.loadRequest = initialURL
    }

    /// Request a navigation to `url`. Sets ``loadRequest`` for the view to pick
    /// up and seeds the address bar so it reflects the target immediately.
    ///
    /// - Parameter url: The URL to load.
    public func load(_ url: URL) {
        loadRequest = url
        addressText = url.absoluteString
        lastErrorMessage = nil
        savedInteractionState = nil
    }

    /// Store a new WebKit interaction-state snapshot when WebKit provides one.
    ///
    /// - Parameter data: The `WKWebView.interactionState` data snapshot, or
    ///   `nil` when WebKit has no restorable state yet.
    public func saveInteractionState(_ data: Data?) {
        guard let data else { return }
        savedInteractionState = data
    }

    /// Update the desktop-site preference and request a reload when a page is
    /// already loaded.
    ///
    /// - Parameter value: Whether subsequent loads should prefer desktop mode.
    public func setPrefersDesktopSite(_ value: Bool) {
        guard prefersDesktopSite != value else { return }
        prefersDesktopSite = value
        if loadRequest == nil, currentURL != nil {
            request(.reload)
        }
    }

    /// Flip the desktop-site preference.
    public func togglePrefersDesktopSite() {
        setPrefersDesktopSite(!prefersDesktopSite)
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
        lastErrorMessage = nil
    }

    /// Mark a successful navigation finish: loading ends and progress completes.
    public func navigationDidFinish() {
        isLoading = false
        estimatedProgress = 1
    }

    /// Mark a navigation failure with a user-facing message.
    ///
    /// - Parameter message: The error description to surface in the chrome.
    public func navigationDidFail(message: String) {
        isLoading = false
        estimatedProgress = 0
        lastErrorMessage = message
    }
}
