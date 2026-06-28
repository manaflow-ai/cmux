/// The app-side seam ``BrowserFindCoordinator`` drives for the find-in-page state
/// it orchestrates but does not own. `BrowserPanel` conforms.
///
/// Find-in-page mixes package-ownable orchestration (running the find service,
/// applying match counts, sequencing the focus-request lease) with state that
/// must stay on the panel: the `@Published` `searchState` SwiftUI binds to, the
/// `@Published` focus-request generation the find bar observes, the panel's
/// semantic `preferredFocusIntent`, and the panel-id-scoped `NotificationCenter`
/// posts the AppKit find field listens for. The coordinator reaches each of those
/// through this seam so it never touches the web view, the window, or the
/// `BrowserSearchState`/`BrowserPanelFocusIntent` types declared app-side.
///
/// `@MainActor` because every witness is a main-actor panel property and the
/// coordinator that calls them is `@MainActor`, so each forward stays a plain
/// main-actor call with no bridging.
@MainActor
public protocol BrowserFindHosting: AnyObject {
    /// The find focus-request generation (`searchFocusRequestGeneration`). The
    /// lease methods bump it (`&+= 1`) to claim or invalidate focus ownership; the
    /// find bar observes the published value to decide whether to apply a focus
    /// request. Read by ``BrowserFindCoordinator/canApplySearchFocusRequest(_:)``
    /// and the navigation-restore re-post.
    var searchFocusRequestGeneration: UInt64 { get set }

    /// Whether the find bar is currently shown (`searchState != nil`).
    var hasFindSearchState: Bool { get }

    /// Whether the panel's semantic focus target is the find field
    /// (`preferredFocusIntent == .findField`).
    var prefersFindFieldFocus: Bool { get }

    /// The current find needle (`searchState?.needle`), or `nil` when the find bar
    /// is hidden. Read when replaying the search after a navigation.
    var findSearchNeedle: String? { get }

    /// The 5-character panel-id prefix used in find debug log lines
    /// (`String(id.uuidString.prefix(5))`).
    var findDebugPanelIDPrefix: String { get }

    /// Writes the match total into the find bar state (`searchState?.total = value`).
    func setFindMatchTotal(_ value: UInt?)

    /// Writes the selected-match index into the find bar state
    /// (`searchState?.selected = value`).
    func setFindMatchSelected(_ value: UInt?)

    /// Sets the panel's semantic focus target to the find field
    /// (`preferredFocusIntent = .findField`).
    func setPreferredFocusToFindField()

    /// Ensures the find bar state exists for a `startFind`, recovering the last
    /// needle when it had to be created. Mirrors the panel's original sequence:
    /// create `BrowserSearchState(needle: lastSearchNeedle)` only when there is no
    /// current state, and report whether the field text should be selected
    /// (`created && !recoveredNeedle.isEmpty`).
    /// - Returns: `true` when the find field should select-all on focus.
    func prepareFindSearchStateForStart() -> Bool

    /// Clears any pending address-bar focus request and posts the address-bar-blur
    /// notification, matching `startFind`'s pre-focus cleanup.
    func clearPendingAddressBarFocusForFind()

    /// Hides the find bar (`searchState = nil`), which triggers the panel's own
    /// teardown (highlight clear + lease invalidation) via the state `didSet`.
    func clearFindSearchState()

    /// Posts the panel-id-scoped browser search-focus notification the AppKit find
    /// field listens for. Stays app-side because it reads the panel's live window
    /// and posts with the panel id as the notification object.
    /// - Parameters:
    ///   - reason: A short tag identifying the post site, for debug logging.
    ///   - generation: The focus-request generation this post is claiming.
    ///   - selectAll: Whether the find field should select its existing text.
    func postBrowserSearchFocusNotification(reason: String, generation: UInt64, selectAll: Bool)

    /// Exits browser focus mode before find takes focus (`clearBrowserFocusMode`).
    func clearBrowserFocusMode(reason: String)

    /// Returns focus to the web view after the find bar is dismissed (`focus()`).
    func focus()
}
