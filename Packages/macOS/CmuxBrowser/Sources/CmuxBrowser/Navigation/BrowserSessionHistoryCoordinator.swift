public import Foundation

/// Owns one `BrowserPanel`'s restored back/forward session history: the pure
/// ``RestoredSessionHistory`` value state machine plus the reconciliation,
/// snapshot, restore, traversal-decision, and availability-refresh flows that
/// drive it. Every live WebKit input and every published effect is forwarded
/// through the app-side ``BrowserSessionHistoryHosting`` seam, so the package
/// reaches no `WKWebView` or `@Published` panel state.
///
/// `@MainActor` because the panel that owns it is `@MainActor` and every entry
/// point runs on a main-actor WebKit/omnibar turn, so the host forwards stay
/// plain calls with no bridging.
@MainActor
public final class BrowserSessionHistoryCoordinator {
    /// The app-side host providing live WebKit state and performing the resolved
    /// effects. Weak because the host (`BrowserPanel`) owns this coordinator
    /// strongly and outlives it, so this is non-nil whenever a method runs.
    public weak var host: (any BrowserSessionHistoryHosting)?

    /// The replayable back/forward session history this surface restores from a
    /// prior launch. The pure stack state machine; this coordinator owns the
    /// instance, feeds it the host's resolved live current URL, and forwards the
    /// `WKWebView` calls its decisions return through the host.
    private var restoredSessionHistory: RestoredSessionHistory

    /// Creates an empty, inactive coordinator.
    ///
    /// - Parameter sanitizer: Normalizes URLs for persistence and replay; its
    ///   temporary-URL classification (diff viewer + remote loopback proxy alias)
    ///   is supplied app-side.
    public init(sanitizer: SessionHistoryURLSanitizer) {
        self.restoredSessionHistory = RestoredSessionHistory(sanitizer: sanitizer)
    }

    /// Whether restored session-history replay is currently active.
    public var usesRestoredSessionHistory: Bool {
        restoredSessionHistory.usesRestoredSessionHistory
    }

    /// The URL of the entry the restored history currently points at.
    public var restoredHistoryCurrentURL: URL? {
        restoredSessionHistory.current
    }

    /// Whether any restored state is present (used to keep a surface alive across
    /// workspace-context changes).
    public var hasRestoredState: Bool {
        restoredSessionHistory.hasRestoredState
    }

    /// Captures the current back/forward URLs for session persistence, realigning
    /// to the live current entry first.
    public func sessionNavigationHistorySnapshot() -> SessionNavigationHistorySnapshot {
        realignToLiveCurrentIfPossible()

        return restoredSessionHistory.snapshot(
            nativeBackURLs: host?.nativeBackForwardBackURLs ?? [],
            nativeForwardURLs: host?.nativeBackForwardForwardURLs ?? [],
            isLiveAligned: isLiveAlignedWithRestoredCurrent
        )
    }

    /// Loads restored stacks from persisted strings, refreshing availability when
    /// replay becomes active.
    public func restoreSessionNavigationHistory(
        backHistoryURLStrings: [String],
        forwardHistoryURLStrings: [String],
        currentURLString: String?
    ) {
        let activated = restoredSessionHistory.restore(
            backHistoryURLStrings: backHistoryURLStrings,
            forwardHistoryURLStrings: forwardHistoryURLStrings,
            currentURLString: currentURLString
        )
        guard activated else { return }
        refreshNavigationAvailability()
    }

    /// Resolves the restored back-request decision, realigning first. Returns
    /// `true` when the restored-history path handled the request; `false` when the
    /// caller should defer to WebKit's native `goBack()`.
    public func goBack() -> Bool {
        guard usesRestoredSessionHistory, let host else { return false }
        realignToLiveCurrentIfPossible()

        let decision = restoredSessionHistory.decideGoBack(
            isLiveAligned: isLiveAlignedWithRestoredCurrent,
            nativeCanGoBack: host.nativeCanGoBack,
            resolvedCurrentURL: host.resolvedCurrentSessionHistoryURL()
        )
        switch decision {
        case .navigate(let targetURL):
            refreshNavigationAvailability()
            host.navigate(toRestoredSessionHistoryURL: targetURL)
        case .nativeGoBack:
            return false
        case .nativeGoForward, .refreshOnly:
            refreshNavigationAvailability()
        }
        return true
    }

    /// Resolves the restored forward-request decision, realigning first. Returns
    /// `true` when the restored-history path handled the request; `false` when the
    /// caller should defer to WebKit's native `goForward()`.
    public func goForward() -> Bool {
        guard usesRestoredSessionHistory, let host else { return false }
        realignToLiveCurrentIfPossible()

        let decision = restoredSessionHistory.decideGoForward(
            nativeCanGoForward: host.nativeCanGoForward,
            resolvedCurrentURL: host.resolvedCurrentSessionHistoryURL()
        )
        switch decision {
        case .nativeGoForward:
            return false
        case .navigate(let targetURL):
            refreshNavigationAvailability()
            host.navigate(toRestoredSessionHistoryURL: targetURL)
        case .nativeGoBack, .refreshOnly:
            refreshNavigationAvailability()
        }
        return true
    }

    /// Recomputes the surface's back/forward availability from the host's native
    /// flags combined with any restored stacks, publishing it through the host.
    public func refreshNavigationAvailability() {
        guard let host else { return }
        let availability = restoredSessionHistory.availability(
            nativeCanGoBack: host.nativeCanGoBack,
            nativeCanGoForward: host.nativeCanGoForward
        )
        host.setNavigationAvailability(
            canGoBack: availability.canGoBack,
            canGoForward: availability.canGoForward
        )
    }

    /// Deactivates replay and clears every restored stack, refreshing availability
    /// when replay was active.
    public func abandonIfNeeded() {
        guard restoredSessionHistory.abandon() else { return }
        refreshNavigationAvailability()
    }

    /// Realigns the restored stacks to the host's resolved live current URL when
    /// WebKit navigated off the restored current entry, refreshing availability
    /// and emitting the forward-clear log identically to the pre-extraction code.
    public func realignToLiveCurrentIfPossible() {
        switch restoredSessionHistory.realign(toLiveCurrentURL: host?.resolvedLiveSessionHistoryURL()) {
        case .noChange:
            return
        case .rebalanced:
            refreshNavigationAvailability()
        case .clearedForward(let liveCurrentString):
            host?.logRestoredSessionHistoryForwardClear(liveCurrentString: liveCurrentString)
            refreshNavigationAvailability()
        }
    }

    private var isLiveAlignedWithRestoredCurrent: Bool {
        restoredSessionHistory.isLiveAligned(withLiveCurrentURL: host?.resolvedLiveSessionHistoryURL())
    }
}
