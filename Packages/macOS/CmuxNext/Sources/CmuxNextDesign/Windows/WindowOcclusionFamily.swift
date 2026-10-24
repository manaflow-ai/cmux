public import AppKit
import CmuxNextCompat
import ObjectiveC

/// A view that hears when its window comes on or goes off screen (``WindowOcclusionFamily``).
@MainActor
public protocol WindowOcclusionFollowing: AnyObject {
    /// The window's occlusion changed: it was covered, minimized, ordered out, moved to another
    /// Space, or came back. Read ``WindowDrawPolicy/isDrawable(_:)`` for the new state.
    func windowOcclusionDidChange()
}

/// Tells the views of one window that its occlusion changed, observing AppKit's notices once per
/// window (PATTERNS.md P3, as ``WindowKeyFamily`` does for key state).
///
/// A view that must stop work while nobody sees its window (a hidden cmux page's renderer freezes,
/// PageWebView+ChromiumCost.swift) used to need an observer of its own: N observers per occlusion
/// notice. The family observes `didChangeOcclusionStateNotification`, `didMiniaturizeNotification`
/// and `didDeminiaturizeNotification` of its window only while it has a follower, and calls only
/// its followers. It lives as long as its window (an associated object), so no process-wide
/// instance exists.
///
/// ```swift
/// override func viewWillMove(toWindow newWindow: NSWindow?) {
///     window.map(WindowOcclusionFamily.of)?.remove(self)
///     newWindow.map(WindowOcclusionFamily.of)?.add(self)
/// }
/// ```
@MainActor
public final class WindowOcclusionFamily {
    private weak var window: NSWindow?
    private let center: NotificationCenter
    private let followers = NSHashTable<AnyObject>.weakObjects()
    private var observers: [MainActorObservation] = []

    private static var key: UInt8 = 0

    /// The family of `window`, made on first use with `center` (a later call returns that family
    /// and ignores its argument; tests pass their own center).
    ///
    /// - Parameters:
    ///   - window: The window.
    ///   - center: Where the window's notices are posted.
    /// - Returns: The window's family.
    public static func of(_ window: NSWindow, center: NotificationCenter = .default) -> WindowOcclusionFamily {
        if let existing = objc_getAssociatedObject(window, &key) as? WindowOcclusionFamily { return existing }
        let family = WindowOcclusionFamily(window: window, center: center)
        objc_setAssociatedObject(window, &key, family, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return family
    }

    private init(window: NSWindow, center: NotificationCenter) {
        self.window = window
        self.center = center
    }

    /// The views it calls now (tests).
    public var followerCount: Int { followers.allObjects.count }
    /// It observes the window's notices (only while it has a follower).
    public var isObserving: Bool { !observers.isEmpty }

    /// Calls `follower` on each occlusion change of the window from now on.
    public func add(_ follower: any WindowOcclusionFollowing) {
        followers.add(follower as AnyObject)
        guard observers.isEmpty, let window else { return }
        let names = [NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification,
                     NSWindow.didDeminiaturizeNotification]
        observers = names.map { name in
            MainActorObservation(name, object: window, center: center) { [weak self] in self?.changed() }
        }
    }

    /// Stops calling `follower`; the last one leaving ends the observation.
    public func remove(_ follower: any WindowOcclusionFollowing) {
        followers.remove(follower as AnyObject)
        if followers.allObjects.isEmpty { observers.removeAll() }
    }

    private func changed() {
        for case let follower as any WindowOcclusionFollowing in followers.allObjects {
            follower.windowOcclusionDidChange()
        }
    }
}
