public import AppKit
import CmuxNextCompat
import ObjectiveC

/// Whether one window is on screen (``WindowDrawPolicy/isOnScreen(_:)``), observed once per window
/// for everything in it that pauses work while the window is covered (PATTERNS.md P3).
///
/// Each such view used to observe the window's occlusion notice itself: one observer per view. The
/// window's family observes it once, only while it has a follower, and calls its followers only
/// when the state flips. It lives as long as its window (an associated object), so no process-wide
/// instance exists.
///
/// ```swift
/// WindowOcclusionFamily.of(window).follow(self) { [weak self] visible in self?.windowVisibilityChanged(visible) }
/// // ...when the view leaves the window:
/// WindowOcclusionFamily.of(window).unfollow(self)
/// ```
///
/// Tests pass their own center and on-screen answer to ``of(_:center:onScreen:)`` before anything
/// else asks for the window's family, then post `NSWindow.didChangeOcclusionStateNotification` to it.
@MainActor
public final class WindowOcclusionFamily {
    private weak var window: NSWindow?
    private let center: NotificationCenter
    private let onScreen: @MainActor (NSWindow) -> Bool
    private var followers: [ObjectIdentifier: Follower] = [:]
    private var observer: MainActorObservation?

    /// Whether the window was on screen at its last notice (or when the first follower came).
    public private(set) var isVisible: Bool
    /// How many followers it calls now (tests read it).
    public var followerCount: Int { followers.values.filter { $0.owner != nil }.count }
    /// It observes the window's occlusion notice (only while it has a follower).
    public var isObserving: Bool { observer != nil }

    private static var key: UInt8 = 0

    /// The family of `window`, made on first use with `center` and `onScreen` (a later call returns
    /// that family and ignores both).
    ///
    /// - Parameters:
    ///   - window: The window whose occlusion the family follows.
    ///   - center: Where the window's occlusion notice arrives (tests pass their own).
    ///   - onScreen: Whether the window is on screen now (``WindowDrawPolicy/isOnScreen(_:)``;
    ///     tests pass their own answer).
    public static func of(_ window: NSWindow, center: NotificationCenter = .default,
                          onScreen: @escaping @MainActor (NSWindow) -> Bool = { WindowDrawPolicy.isOnScreen($0) })
        -> WindowOcclusionFamily {
        if let existing = objc_getAssociatedObject(window, &key) as? WindowOcclusionFamily { return existing }
        let family = WindowOcclusionFamily(window: window, center: center, onScreen: onScreen)
        objc_setAssociatedObject(window, &key, family, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return family
    }

    private init(window: NSWindow, center: NotificationCenter, onScreen: @escaping @MainActor (NSWindow) -> Bool) {
        self.window = window
        self.center = center
        self.onScreen = onScreen
        isVisible = onScreen(window)
    }

    /// Calls `changed` with the window's new state each time it flips, until ``unfollow(_:)`` or
    /// until `owner` goes away. A second call for the same owner replaces its handler.
    ///
    /// - Parameters:
    ///   - owner: Who follows (held weakly); the key for ``unfollow(_:)``.
    ///   - changed: Told `true` when the window comes on screen, `false` when it is covered.
    public func follow(_ owner: AnyObject, _ changed: @escaping @MainActor (Bool) -> Void) {
        if observer == nil, let window {
            // Notices while it did not observe: read the window now.
            isVisible = onScreen(window)
            observer = MainActorObservation(NSWindow.didChangeOcclusionStateNotification, object: window, center: center) { [weak self] in
                self?.occlusionChanged()
            }
        }
        followers[ObjectIdentifier(owner)] = Follower(owner: owner, changed: changed)
    }

    /// Stops calling `owner`. The last follower to leave stops the observation.
    public func unfollow(_ owner: AnyObject) {
        followers.removeValue(forKey: ObjectIdentifier(owner))
        dropGone()
    }

    private func occlusionChanged() { // perf-hot: 0.1ms window-occlusion (once per window per notice; its followers only on a flip)
        guard let window else { return }
        let visible = onScreen(window)
        guard visible != isVisible else { return }
        isVisible = visible
        for follower in followers.values {
            if follower.owner != nil { follower.changed(visible) }
        }
        dropGone()
    }

    /// Forgets followers that went away; with none left, stops observing.
    private func dropGone() {
        followers = followers.filter { $0.value.owner != nil }
        if followers.isEmpty { observer = nil }
    }
}

/// One follower of a ``WindowOcclusionFamily``.
@MainActor
private struct Follower {
    weak var owner: AnyObject?
    let changed: @MainActor (Bool) -> Void
}
