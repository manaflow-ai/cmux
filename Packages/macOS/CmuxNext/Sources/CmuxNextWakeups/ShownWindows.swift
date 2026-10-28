/// Whether any of the app's windows shows now: one of the window nodes it tracks is
/// ``Visibility/visible`` (an occluded, miniaturized or closed window, a hidden app and sleeping
/// displays all count as not shown, as in ``VisibilityNode/isVisible``).
///
/// Background polls that only feed what a window shows (the GitHub feed, the web-updates check)
/// book nothing while nothing shows and run what came due once a window shows again,
/// the way Chromium stops a page's work while its WebContents is hidden or
/// occluded (`content/public/browser/visibility.h`, `WebContentsImpl::UpdateWebContentsVisibility`).
///
/// The app's visibility root owns one and tracks each window's node when the window is made. A
/// closed window's node detaches (it flips to hidden); a released node is dropped at the next
/// ``track(_:)``. Tests make their own over root nodes. It counts any nodes it tracks: the feed keeps
/// one over its surfaces' nodes (page tabs, panel, sidebar sections), so its GitHub poll stops while a
/// window shows no feed.
///
/// ```swift
/// let shown = ShownWindows()
/// shown.track(window.visibility)
/// let token = shown.observe { anyShown in anyShown ? poll.resume() : poll.pause() }
/// ```
@MainActor public final class ShownWindows {
    /// Whether one tracked window is visible now. O(1): the visible set is kept, never walked.
    public var anyShown: Bool { !visible.isEmpty }

    /// The tracked windows' flip subscriptions, by node.
    private var tracked: [ObjectIdentifier: VisibilitySubscription] = [:]
    /// The tracked windows visible now.
    private var visible: Set<ObjectIdentifier> = []
    /// Held weakly: releasing an observation ends it and releases its closure.
    private var observers: [WeakObservation] = []

    /// No window tracked yet.
    public init() {}

    /// Follows `node` (a window's) while it lives. Tracking a node again does nothing.
    public func track(_ node: VisibilityNode) {
        // Released nodes go first, so a new node at a released one's address is tracked.
        for (id, subscription) in tracked where !subscription.isActive {
            tracked[id] = nil
            set(id, visible: false)
        }
        let id = ObjectIdentifier(node)
        guard tracked[id] == nil else { return }
        tracked[id] = node.subscribe(owner: "ShownWindows") { [weak self] visibility in
            self?.set(id, visible: visibility == .visible)
        }
        set(id, visible: node.isVisible)
    }

    /// Calls `onChange` with ``anyShown`` each time it flips, until the returned observation is
    /// cancelled or released. It is not called for the current value.
    public func observe(_ onChange: @escaping @MainActor (Bool) -> Void) -> ShownWindowsObservation {
        let observation = ShownWindowsObservation(onChange: onChange)
        observers.removeAll { $0.observation?.isActive != true }
        observers.append(WeakObservation(observation: observation))
        return observation
    }

    /// The windows tracked now (tests).
    public var trackedCount: Int { tracked.count }

    private func set(_ id: ObjectIdentifier, visible isVisible: Bool) {
        let before = anyShown
        if isVisible { visible.insert(id) } else { visible.remove(id) }
        let after = anyShown
        guard after != before else { return }
        observers.removeAll { $0.observation?.isActive != true }
        for observation in observers.compactMap(\.observation) where observation.isActive { observation.onChange(after) }
    }

    private struct WeakObservation {
        weak var observation: ShownWindowsObservation?
    }
}

/// One ``ShownWindows/observe(_:)`` registration. The source holds it weakly: releasing it ends
/// the observation and releases its closure; ``cancel()`` ends it early.
@MainActor public final class ShownWindowsObservation {
    let onChange: @MainActor (Bool) -> Void
    /// Whether ``cancel()`` has not been called.
    private(set) var isActive = true

    init(onChange: @escaping @MainActor (Bool) -> Void) {
        self.onChange = onChange
    }

    /// Stops the observer; later calls do nothing.
    public func cancel() { isActive = false }
}
