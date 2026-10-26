public import AppKit
public import CmuxNextWakeups
import ObjectiveC

/// One window in the visibility tree, and the one source of whether it is on screen
/// (plans/cmux-next/chrome-parity/p06-scheduler.md, task 022).
///
/// Its node's own state follows the window: miniaturized is ``Visibility/hidden``, an
/// `occlusionState` without `.visible` is ``Visibility/occluded``, otherwise ``Visibility/visible``.
/// The app's node (``AppVisibilitySource``) is its parent, so a hidden app or sleeping displays
/// cap it. Chromium computes the same three values per WebContents from its NSWindow
/// (`content/app_shim_remote_cocoa/web_contents_view_cocoa.mm`, `-updateWebContentsVisibility`,
/// on `windowDidChangeOcclusionState:` and miniaturize).
///
/// It observes the occlusion and miniaturize notices once, through the window's ``WindowEvents``.
/// ``WindowDrawPolicy/isOnScreen(_:)`` reads ``isOnScreen``; views and controllers that only need
/// the flips subscribe to ``node`` instead of observing the window themselves.
///
/// The window's owner makes it with the window (``of(_:name:app:events:read:)``), before any view
/// reaches the window, so its observer runs before the views' own occlusion handlers.
@MainActor public final class WindowVisibilitySource {
    /// Reads a window's own state (tests drive transitions without a screen).
    public typealias Read = @MainActor (NSWindow) -> Visibility

    /// The window's node: the parent of its workspaces' nodes.
    public let node: VisibilityNode
    private weak var window: NSWindow?
    private let read: Read
    private var subscriptions: [EventSubscription] = []

    private static var associationKey: UInt8 = 0

    /// The notices that change a window's own state.
    public static let notices: [Notification.Name] = [
        NSWindow.didChangeOcclusionStateNotification,
        NSWindow.didMiniaturizeNotification,
        NSWindow.didDeminiaturizeNotification,
    ]

    /// AppKit's answer for `window`: miniaturized is hidden; on screen when `occlusionState`
    /// contains `.visible` (key or active state plays no part); otherwise occluded.
    public static func appKitState(of window: NSWindow) -> Visibility {
        if window.isMiniaturized { return .hidden }
        return window.occlusionState.contains(.visible) ? .visible : .occluded
    }

    /// Follows `window` through `events`.
    ///
    /// - Parameters:
    ///   - window: The window (held weakly).
    ///   - name: The node's name in diagnostics.
    ///   - app: The app's node, its parent; nil makes the window's node a root.
    ///   - events: The window's notices (tests pass their own center's).
    ///   - read: The window's own state (``appKitState(of:)``).
    public init(window: NSWindow, name: String, app: VisibilityNode?, events: WindowEvents,
                read: @escaping Read = WindowVisibilitySource.appKitState(of:)) {
        self.window = window
        self.read = read
        let own = read(window)
        node = app.map { VisibilityNode(name, own: own, parent: $0) } ?? VisibilityNode(root: name, own: own)
        subscriptions = Self.notices.map { notice in
            events.subscribe(notice, owner: "WindowVisibilitySource") { [weak self] in self?.refresh() }
        }
    }

    /// `window`'s source, made on first use and kept alive by the window. A later call returns the
    /// same source and ignores its other arguments.
    public static func of(_ window: NSWindow, name: String = "window", app: VisibilityNode? = nil,
                          events: WindowEvents? = nil,
                          read: @escaping Read = WindowVisibilitySource.appKitState(of:)) -> WindowVisibilitySource {
        if let existing = installed(on: window) { return existing }
        let source = WindowVisibilitySource(window: window, name: name, app: app, events: events ?? WindowEvents.of(window), read: read)
        objc_setAssociatedObject(window, &associationKey, source, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return source
    }

    /// `window`'s source if one was made; nil makes nothing.
    public static func installed(on window: NSWindow) -> WindowVisibilitySource? {
        objc_getAssociatedObject(window, &associationKey) as? WindowVisibilitySource
    }

    /// Whether the window itself is at least partly on screen: its own state, as AppKit reports
    /// it. A hidden app and sleeping displays already leave every window occluded in AppKit, so
    /// drawing never waits for the app's notice; work gated on the node reads ``node`` instead.
    public var isOnScreen: Bool { node.own == .visible }

    /// Reads the window's state again (the owner calls it after showing the window).
    public func refresh() {
        guard let window else { return }
        node.set(read(window))
    }
}
