public import AppKit
public import CmuxNextWakeups
import ObjectiveC

/// One window in the visibility tree, and the one source of whether it is on screen
/// (plans/cmux-next/chrome-parity/p06-scheduler.md, task 022).
///
/// Its node's own state follows the window: miniaturized is ``Visibility/hidden``, an
/// `occlusionState` without `.visible` is ``Visibility/occluded``, and so is a window its
/// ``WindowOcclusionFamily`` calls occluded (fully covered by an opaque cmux
/// window of the same size, which AppKit still reports visible, crbug.com/883031); otherwise
/// ``Visibility/visible``.
/// The app's node (``AppVisibilitySource``) is its parent, so a hidden app or sleeping displays
/// cap it. Chromium computes the same three values per WebContents from its NSWindow
/// (`content/app_shim_remote_cocoa/web_contents_view_cocoa.mm`, `-updateWebContentsVisibility`,
/// on `windowDidChangeOcclusionState:` and miniaturize).
///
/// It observes the occlusion and miniaturize notices once, through the window's ``WindowEvents``,
/// and the family's flips as a content-stage subscriber. Views and controllers that need the flips
/// subscribe to ``node`` instead of observing the window themselves. Drawing does not read the node:
/// ``WindowDrawPolicy/isOnScreen(_:)`` applies the AppKit rule (``appKitState(of:)``) to AppKit's
/// live state, so a reader that observes the window's notice directly never sees an answer older
/// than AppKit's, and a drawing reader asks the family itself (`TerminalSurfaceView`).
///
/// The window's owner makes it with the window (``of(_:name:app:events:read:)``), under the app's
/// node, before any view reaches the window. A window with no owner (a demo or test window) gets a
/// root source from the first view that asks; its own state is AppKit's, which already leaves the
/// window occluded while the app is hidden or the displays sleep.
@MainActor public final class WindowVisibilitySource {
    /// Reads a window's own state (tests drive transitions without a screen).
    public typealias Read = @MainActor (NSWindow) -> Visibility

    /// The window's node: the parent of its workspaces' nodes.
    public let node: VisibilityNode
    private weak var window: NSWindow?
    private let read: Read
    /// The notices it follows; kept here, as a subscription holds its fan-out only weakly.
    private let events: WindowEvents
    private var subscriptions: [EventSubscription] = []
    /// The window's occlusion family; the window keeps it alive too, and it holds no reference back.
    private let family: WindowOcclusionFamily
    private var familyFlips: WindowOcclusionSubscription?

    private static let sources = ObjectAssociation<WindowVisibilitySource>()

    /// The notices that change a window's own state.
    public static let notices: [Notification.Name] = [
        // raw-observer-allow: the WindowEvents subscription recipe R-notif asks for (one observer per window and notice); only the notice's name matches
        NSWindow.didChangeOcclusionStateNotification,
        // raw-observer-allow: the WindowEvents subscription recipe R-notif asks for (one observer per window and notice); only the notice's name matches
        NSWindow.didMiniaturizeNotification,
        // raw-observer-allow: the WindowEvents subscription recipe R-notif asks for (one observer per window and notice); only the notice's name matches
        NSWindow.didDeminiaturizeNotification,
    ]

    /// AppKit's answer for `window`: miniaturized is hidden; on screen when `occlusionState`
    /// contains `.visible` (key or active state plays no part); otherwise occluded.
    public static func appKitState(of window: NSWindow) -> Visibility {
        if window.isMiniaturized { return .hidden }
        return window.occlusionState.contains(.visible) ? .visible : .occluded
    }

    /// The window's own state: the read answer, capped at ``Visibility/occluded`` while the family
    /// says occluded. A miniaturized window stays ``Visibility/hidden``.
    private static func state(_ appKit: Visibility, family: WindowOcclusionFamily) -> Visibility {
        family.isOccluded ? min(appKit, .occluded) : appKit
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
        self.events = events
        let family = WindowOcclusionFamily.of(window)
        self.family = family
        let own = Self.state(read(window), family: family)
        node = app.map { VisibilityNode(name, own: own, parent: $0) } ?? VisibilityNode(root: name, own: own)
        subscriptions = Self.notices.map { notice in
            events.subscribe(notice, owner: "WindowVisibilitySource") { [weak self] in self?.refresh() }
        }
        familyFlips = family.subscribe(.content, owner: "WindowVisibilitySource") { [weak self] _ in self?.refresh() }
    }

    /// `window`'s source, made on first use and kept alive by the window. A later call returns the
    /// same source and ignores its other arguments.
    public static func of(_ window: NSWindow, name: String = "window", app: VisibilityNode? = nil,
                          events: WindowEvents? = nil,
                          read: @escaping Read = WindowVisibilitySource.appKitState(of:)) -> WindowVisibilitySource {
        if let existing = installed(on: window) { return existing }
        let source = WindowVisibilitySource(window: window, name: name, app: app, events: events ?? WindowEvents.of(window), read: read)
        sources.set(source, on: window)
        return source
    }

    /// `window`'s source if one was made; nil makes nothing.
    public static func installed(on window: NSWindow) -> WindowVisibilitySource? {
        sources.value(on: window)
    }

    /// Reads the window's state again (the owner calls it after showing the window).
    public func refresh() {
        guard let window else { return }
        node.set(Self.state(read(window), family: family))
    }
}
