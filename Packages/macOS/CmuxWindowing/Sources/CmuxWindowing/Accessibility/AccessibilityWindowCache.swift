public import AppKit

/// Caches `AXWindows` responses so repeated AX polls can reuse the same
/// snapshot while the app window graph is unchanged. Help-tag tooltip windows
/// are excluded from the snapshot because AX clients expect every element in
/// `AXWindows` to behave like a window. Only `.windows` is cached; `.children`
/// and `.visibleChildren` fall through to AppKit so the menu bar stays present
/// in the accessibility tree for VoiceOver and other AX clients. `.mainWindow`
/// / `.focusedWindow` also fall through, so AppKit remains authoritative on
/// focus transitions.
///
/// Construct one instance at the composition root and inject it behind
/// ``AccessibilityWindowCaching``; the app-target `NSApplication` swizzle
/// forwards to it.
///
/// The cache's own value state (the cached token and snapshot) carries no
/// actor isolation: every access is confined to the main thread by contract
/// (the swizzle guards `Thread.isMainThread` before calling
/// ``resolve(attribute:application:)``, and the window-close observer is
/// delivered on `.main`). Only the boundary methods that read main-actor
/// `NSWindow`/`NSApplication` properties are annotated `@MainActor`.
///
/// `@unchecked Sendable` solely so the `.main`-delivered `@Sendable`
/// window-close observer block may capture the instance to invalidate it
/// synchronously. Every read and write of the cache's mutable state happens on
/// the main thread, so there is no actual data race; this mirrors the
/// sanctioned `NotificationObserverToken` escape in `CmuxSettings`.
public final class AccessibilityWindowCache: AccessibilityWindowCaching, @unchecked Sendable {
    /// Identity-and-state fingerprint of a single window, used to detect when
    /// the cached snapshot is stale.
    public struct WindowToken: Equatable {
        let identity: ObjectIdentifier
        let windowNumber: Int
        let isVisible: Bool
        let isMiniaturized: Bool
    }

    /// Fingerprint of the whole window list; equal tokens mean the cached
    /// snapshot is still valid.
    public struct StateToken: Equatable {
        let windows: [WindowToken]

        /// Builds a state token from the current window list, ignoring the
        /// same help-tag windows the snapshot omits. `@MainActor` because it
        /// reads main-actor-isolated `NSWindow` properties.
        @MainActor
        public init(windows: [NSWindow]) {
            self.windows = windows.filter(isPublishableAXWindow).map {
                WindowToken(
                    identity: ObjectIdentifier($0),
                    windowNumber: $0.windowNumber,
                    isVisible: $0.isVisible,
                    isMiniaturized: $0.isMiniaturized
                )
            }
        }
    }

    /// The cached window-hierarchy snapshot returned for `.windows`.
    public struct Snapshot {
        let windows: [NSWindow]

        /// Builds a snapshot from a window list. `@MainActor` because it reads
        /// main-actor-isolated accessibility roles from `NSWindow`.
        @MainActor
        public init(windows: [NSWindow]) {
            self.windows = windows.filter(isPublishableAXWindow)
        }
    }

    private let notificationCenter: NotificationCenter
    private var cachedStateToken: StateToken?
    private var cachedSnapshot: Snapshot?
    private var windowCloseObserver: (any NSObjectProtocol)?

    /// Creates a cache observing `notificationCenter` for window-close events.
    public init(notificationCenter: NotificationCenter = .default) {
        self.notificationCenter = notificationCenter
        // Drop strong refs to any window the instant it closes so the cache
        // never keeps a closed NSWindow alive between AX polls.
        windowCloseObserver = notificationCenter.addObserver(
            forName: NSWindow.willCloseNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.invalidate()
        }
    }

    deinit {
        if let windowCloseObserver {
            notificationCenter.removeObserver(windowCloseObserver)
        }
    }

    /// Drops the cached snapshot so the next query rebuilds it.
    public func invalidate() {
        cachedStateToken = nil
        cachedSnapshot = nil
    }

    @MainActor
    public func resolve(attribute: NSAccessibility.Attribute, application: NSApplication) -> AccessibilityWindowResolution {
        guard Self.supportsCaching(attribute) else { return .passthrough }
        let windows = application.windows
        let stateToken = StateToken(windows: windows)
        let value = value(for: attribute, stateToken: stateToken) {
            Snapshot(windows: windows)
        }
        return .handled(value)
    }

    /// Returns the cached value for `attribute`, building a fresh snapshot via
    /// `builder` only when `stateToken` differs from the cached one. Returns
    /// nil for attributes this cache does not handle.
    @MainActor
    public func value(
        for attribute: NSAccessibility.Attribute,
        stateToken: StateToken,
        builder: () -> Snapshot
    ) -> Any? {
        guard Self.supportsCaching(attribute) else { return nil }

        let snapshot: Snapshot
        if cachedStateToken == stateToken, let cachedSnapshot {
            snapshot = cachedSnapshot
        } else {
            snapshot = builder()
            cachedStateToken = stateToken
            cachedSnapshot = snapshot
        }

        switch attribute.rawValue {
        case NSAccessibility.Attribute.windows.rawValue:
            return snapshot.windows
        default:
            return nil
        }
    }

    private static func supportsCaching(_ attribute: NSAccessibility.Attribute) -> Bool {
        attribute.rawValue == NSAccessibility.Attribute.windows.rawValue
    }
}

/// Help-tag tooltip windows are excluded from `AXWindows` because AX clients
/// expect every element in `AXWindows` to behave like a window. `@MainActor`
/// because it reads the main-actor-isolated accessibility role from `NSWindow`.
@MainActor
private func isPublishableAXWindow(_ window: NSWindow) -> Bool {
    window.accessibilityRole() != .helpTag
}
