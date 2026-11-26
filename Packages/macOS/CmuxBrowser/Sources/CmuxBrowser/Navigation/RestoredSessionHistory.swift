public import Foundation

/// The replayable back/forward history a browser surface restores from a prior
/// launch, plus the native WebKit availability flags it is reconciled against.
///
/// WebKit cannot rehydrate a `WKBackForwardList` from serialized URLs, so cmux
/// keeps its own restored stacks and replays them by issuing fresh navigations.
/// Once the live page accumulates native history, traversal defers to WebKit and
/// the restored stacks are realigned to track the live current entry. This type
/// is a pure value-semantics state machine: it owns the stacks and flags and is
/// driven by the surface, which supplies the live current URL and performs the
/// resulting `WKWebView` calls. It reaches no WebKit, AppKit, or app-target type.
///
/// Storage convention: `back` is ordered oldest-first; `forward` is ordered with
/// the nearest-forward entry at the end so traversal is a `removeLast()` pop.
public struct RestoredSessionHistory: Sendable {
    /// Whether restored session-history replay is currently active. When `false`
    /// the surface uses WebKit's native back-forward list exclusively.
    public private(set) var usesRestoredSessionHistory: Bool = false

    /// Back-list URLs, oldest first.
    public private(set) var back: [URL] = []

    /// Forward-list URLs with the nearest-forward entry last.
    public private(set) var forward: [URL] = []

    /// The URL of the entry the restored history currently points at.
    public private(set) var current: URL?

    private let sanitizer: SessionHistoryURLSanitizer

    /// Creates an empty, inactive restored history.
    ///
    /// - Parameter sanitizer: Normalizes URLs for persistence and replay.
    public init(sanitizer: SessionHistoryURLSanitizer) {
        self.sanitizer = sanitizer
    }

    /// Computes back/forward availability by combining native WebKit flags with
    /// any restored stacks. When restored history is inactive the native flags
    /// pass through unchanged.
    public func availability(nativeCanGoBack: Bool, nativeCanGoForward: Bool) -> NavigationAvailability {
        if usesRestoredSessionHistory {
            return NavigationAvailability(
                canGoBack: nativeCanGoBack || !back.isEmpty,
                canGoForward: nativeCanGoForward || !forward.isEmpty
            )
        }
        return NavigationAvailability(canGoBack: nativeCanGoBack, canGoForward: nativeCanGoForward)
    }

    /// Whether anything would need clearing if the surface's workspace context
    /// changes (any restored state present).
    public var hasRestoredState: Bool {
        current != nil || !back.isEmpty || !forward.isEmpty
    }

    /// Returns whether the resolved live current URL matches the restored current
    /// entry. Treats either side being non-serializable as aligned, matching the
    /// surface's reconciliation contract.
    public func isLiveAligned(withLiveCurrentURL liveCurrentURL: URL?) -> Bool {
        let liveCurrent = sanitizer.serializableSessionHistoryURLString(liveCurrentURL)
        let restoredCurrent = sanitizer.serializableSessionHistoryURLString(current)
        guard let liveCurrent, let restoredCurrent else { return true }
        return liveCurrent == restoredCurrent
    }

    /// Loads restored stacks from persisted strings. Activates replay only when
    /// at least one eligible URL survives sanitization. `forwardHistoryURLStrings`
    /// is supplied nearest-forward-first and stored reversed so traversal pops
    /// from the end.
    ///
    /// - Returns: `true` when replay became active (the caller should refresh
    ///   availability), `false` when nothing eligible was restored.
    @discardableResult
    public mutating func restore(
        backHistoryURLStrings: [String],
        forwardHistoryURLStrings: [String],
        currentURLString: String?
    ) -> Bool {
        let restoredBack = sanitizer.sanitizedSessionHistoryURLs(backHistoryURLStrings)
        let restoredForward = sanitizer.sanitizedSessionHistoryURLs(forwardHistoryURLStrings)
        let restoredCurrent = sanitizer.sanitizedSessionHistoryURL(currentURLString)
        guard !restoredBack.isEmpty || !restoredForward.isEmpty || restoredCurrent != nil else {
            return false
        }

        usesRestoredSessionHistory = true
        back = restoredBack
        forward = Array(restoredForward.reversed())
        current = restoredCurrent
        return true
    }

    /// Captures the current back/forward URLs for persistence, given the native
    /// WebKit back/forward lists and the live alignment.
    ///
    /// - Parameters:
    ///   - nativeBackURLs: WebKit `backForwardList.backList` URLs, oldest first.
    ///   - nativeForwardURLs: WebKit `backForwardList.forwardList` URLs.
    ///   - isLiveAligned: Whether the live current entry matches the restored
    ///     current entry (typically the result of a preceding realign).
    public func snapshot(
        nativeBackURLs: [URL],
        nativeForwardURLs: [URL],
        isLiveAligned: Bool
    ) -> SessionNavigationHistorySnapshot {
        let nativeBack = nativeBackURLs.compactMap { sanitizer.serializableSessionHistoryURLString($0) }
        let nativeForward = nativeForwardURLs.compactMap { sanitizer.serializableSessionHistoryURLString($0) }

        if usesRestoredSessionHistory {
            let backStrings = back.compactMap { sanitizer.serializableSessionHistoryURLString($0) }
            let restoredForward = forward.reversed().compactMap {
                sanitizer.serializableSessionHistoryURLString($0)
            }

            if isLiveAligned {
                return SessionNavigationHistorySnapshot(
                    backHistoryURLStrings: backStrings,
                    forwardHistoryURLStrings: restoredForward.isEmpty ? nativeForward : restoredForward
                )
            }

            return SessionNavigationHistorySnapshot(
                backHistoryURLStrings: backStrings + nativeBack,
                forwardHistoryURLStrings: nativeForward
            )
        }

        return SessionNavigationHistorySnapshot(
            backHistoryURLStrings: nativeBack,
            forwardHistoryURLStrings: nativeForward
        )
    }

    /// The outcome of realigning the restored stacks to a live current URL.
    public enum RealignOutcome: Sendable, Equatable {
        /// Replay inactive or live current unresolved/already current: no change.
        case noChange
        /// Stacks were rebalanced around the live current entry.
        case rebalanced
        /// The live current was not found in either stack and the forward stack
        /// was cleared. The caller should emit the forward-clear debug log.
        case clearedForward(liveCurrentString: String)
    }

    /// Realigns the restored stacks when WebKit navigated to an entry that is not
    /// the restored current (e.g. an in-page link from a replayed page). If the
    /// live entry is found in the back stack, entries after it move to forward;
    /// if found in the forward stack, entries before it move to back; otherwise
    /// the now-stale forward stack is cleared.
    ///
    /// - Parameter liveCurrentURL: The surface's resolved live current URL.
    /// - Returns: A `RealignOutcome` describing what changed so the caller can
    ///   refresh availability and log identically to the pre-extraction code.
    @discardableResult
    public mutating func realign(toLiveCurrentURL liveCurrentURL: URL?) -> RealignOutcome {
        guard usesRestoredSessionHistory else { return .noChange }
        guard let liveCurrentString = sanitizer.serializableSessionHistoryURLString(liveCurrentURL) else {
            return .noChange
        }
        guard sanitizer.serializableSessionHistoryURLString(current) != liveCurrentString else {
            return .noChange
        }

        let restoredBack = back.compactMap { sanitizer.serializableSessionHistoryURLString($0) }
        let restoredForward = forward.reversed().compactMap {
            sanitizer.serializableSessionHistoryURLString($0)
        }
        let restoredCurrent = sanitizer.serializableSessionHistoryURLString(current)

        if let backIndex = restoredBack.lastIndex(of: liveCurrentString) {
            let newBack = Array(restoredBack[..<backIndex])
            var newForward = Array(restoredBack[(backIndex + 1)...])
            if let restoredCurrent {
                newForward.append(restoredCurrent)
            }
            newForward.append(contentsOf: restoredForward)

            back = sanitizer.sanitizedSessionHistoryURLs(newBack)
            forward = Array(sanitizer.sanitizedSessionHistoryURLs(newForward).reversed())
            current = liveCurrentURL
            return .rebalanced
        }

        if let forwardIndex = restoredForward.firstIndex(of: liveCurrentString) {
            var newBack = restoredBack
            if let restoredCurrent {
                newBack.append(restoredCurrent)
            }
            newBack.append(contentsOf: restoredForward[..<forwardIndex])
            let newForward = Array(restoredForward[(forwardIndex + 1)...])

            back = sanitizer.sanitizedSessionHistoryURLs(newBack)
            forward = Array(sanitizer.sanitizedSessionHistoryURLs(newForward).reversed())
            current = liveCurrentURL
            return .rebalanced
        }

        guard !forward.isEmpty else { return .noChange }
        forward.removeAll(keepingCapacity: false)
        return .clearedForward(liveCurrentString: liveCurrentString)
    }

    /// Decides how to satisfy a back request while replay is active.
    ///
    /// - Parameters:
    ///   - isLiveAligned: Whether the live current matches the restored current.
    ///   - nativeCanGoBack: WebKit's `canGoBack`.
    ///   - resolvedCurrentURL: The surface's resolved current URL, pushed onto
    ///     the forward stack when a restored back entry is popped.
    /// - Returns: The traversal decision the surface should apply.
    public mutating func decideGoBack(
        isLiveAligned: Bool,
        nativeCanGoBack: Bool,
        resolvedCurrentURL: URL?
    ) -> SessionHistoryTraversalDecision {
        if (isLiveAligned || !nativeCanGoBack), let targetURL = popBack() {
            if let resolvedCurrentURL {
                forward.append(resolvedCurrentURL)
            }
            current = targetURL
            return .navigate(targetURL)
        }

        if nativeCanGoBack {
            return .nativeGoBack
        }

        return .refreshOnly
    }

    /// Decides how to satisfy a forward request while replay is active.
    ///
    /// - Parameters:
    ///   - nativeCanGoForward: WebKit's `canGoForward`.
    ///   - resolvedCurrentURL: The surface's resolved current URL, pushed onto
    ///     the back stack when a restored forward entry is popped.
    /// - Returns: The traversal decision the surface should apply.
    public mutating func decideGoForward(
        nativeCanGoForward: Bool,
        resolvedCurrentURL: URL?
    ) -> SessionHistoryTraversalDecision {
        if nativeCanGoForward {
            return .nativeGoForward
        }

        guard let targetURL = popForward() else {
            return .refreshOnly
        }
        if let resolvedCurrentURL {
            back.append(resolvedCurrentURL)
        }
        current = targetURL
        return .navigate(targetURL)
    }

    /// Deactivates replay and clears every restored stack. No-op when replay is
    /// already inactive.
    ///
    /// - Returns: `true` when replay was active and is now cleared (the caller
    ///   should refresh availability), `false` otherwise.
    @discardableResult
    public mutating func abandon() -> Bool {
        guard usesRestoredSessionHistory else { return false }
        usesRestoredSessionHistory = false
        back.removeAll(keepingCapacity: false)
        forward.removeAll(keepingCapacity: false)
        current = nil
        return true
    }

    private mutating func popBack() -> URL? {
        back.popLast()
    }

    private mutating func popForward() -> URL? {
        forward.popLast()
    }
}
