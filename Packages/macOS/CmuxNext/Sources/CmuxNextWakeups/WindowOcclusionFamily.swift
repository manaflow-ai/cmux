public import AppKit
public import CmuxNextCompat
import ObjectiveC

/// Whether one window is occluded, and the one place its readers learn it (rendering-DESIGN R6,
/// PATTERNS.md P10a): occluded is AppKit's state (`occlusionState` without `.visible`: minimized,
/// another Space, covered by other apps' windows, the app hidden, the displays asleep), or the window
/// fully covered by one opaque cmux window above it. macOS does not report the second case "for
/// browser windows of similar size" (crbug.com/883031), so Chrome checks it itself
/// (content/app_shim_remote_cocoa/web_contents_occlusion_checker_mac.mm, `-isWindowOccluded:`), and
/// so does the source that feeds this family: CmuxNextDesign's `WindowOcclusionChecker`
/// (`feedingFamilies()`, started at launch with the feature `windowOcclusionFamily`), through
/// ``set(occluded:)``. Without a source the family never flips and nothing pauses.
///
/// It is also the one reader of AppKit's own state (p03-rendering-113): it observes the window's
/// occlusion notice once, through the window's ``WindowEvents``, and reads `occlusionState` live
/// (``isSystemVisible``), so no view or controller observes the notice or reads the state itself.
/// A reader asks ``isOnScreen`` (AppKit's state and the source's) and subscribes for changes; an
/// owner of no window that watches every window (the source, a window's Chromium page children,
/// app-wide diagnostics) uses ``observeSystemChanges(center:_:)``. Chrome keeps the same split: one
/// occlusion checker reads the window server and its `WebContentsViewCocoa`s hear from it
/// (content/app_shim_remote_cocoa/web_contents_occlusion_checker_mac.mm).
///
/// One per window, made on first use and kept alive by the window (``of(_:events:)``), as
/// ``WindowEvents`` and the window's ``FrameScheduler`` are.
///
/// Subscribers hear each flip and each AppKit notice in ``Stage`` order: the content producers
/// first (the window's ``FrameScheduler`` pauses its frame clients, Ghostty surfaces stop drawing,
/// hosted pages are told `occluded`, loops come off), then diagnostics, so a diagnostic never reads
/// a window that is half paused.
///
/// ```swift
/// let family = WindowOcclusionFamily.of(window)
/// watch = family.subscribe(.content, owner: "TerminalSurfaceView") { [weak self] _ in self?.updateOcclusion() }
/// let seen = family.isOnScreen
/// ```
@MainActor public final class WindowOcclusionFamily {
    /// The order subscribers hear a flip in.
    public enum Stage: Int, Sendable, Comparable, CaseIterable {
        /// What draws or makes frames for the window: frame clients, surfaces, pages, loops.
        case content
        /// What only reports on the window (debug counters, invariant monitors).
        case diagnostics

        public static func < (lhs: Stage, rhs: Stage) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// The window (held weakly: the family never keeps it alive).
    public private(set) weak var window: NSWindow?
    /// Nothing of the window can be seen now.
    public private(set) var isOccluded = false
    /// Flips since the family was made (tests and debug.wakeups).
    public private(set) var flips = 0
    /// AppKit occlusion notices of the window delivered since the family was made.
    public private(set) var systemChanges = 0

    /// Reads AppKit's answer for a window (tests pass a fake).
    public typealias SystemVisibility = @MainActor (NSWindow) -> Bool

    private let systemVisible: SystemVisibility
    private var subscriptions: [WeakSubscription] = []
    /// The notices it follows, kept here: a subscription holds its fan-out only weakly.
    private let events: WindowEvents?
    /// Its one subscription to the window's AppKit notice; nil for a family made without events.
    private var systemWatch: EventSubscription?
    /// Counts deliveries: a delivery stops when a subscriber's reaction started a newer one.
    private var generation = 0

    private static var associationKey: UInt8 = 0

    /// AppKit's notice that some of a window came on screen or none of it is left. Its name appears
    /// nowhere else outside Debug files: readers subscribe to the family.
    nonisolated static let systemNotice = NSWindow.didChangeOcclusionStateNotification

    /// A family of `window` that is not installed on it (tests; the app uses ``of(_:events:)``).
    ///
    /// - Parameters:
    ///   - window: The window (held weakly).
    ///   - events: The window's notices; the family follows AppKit's occlusion notice through them.
    ///     Nil follows none (a family only its source drives).
    ///   - systemVisible: AppKit's answer for the window (``appKitVisible(_:)``).
    public init(window: NSWindow, events: WindowEvents? = nil,
                systemVisible: @escaping SystemVisibility = WindowOcclusionFamily.appKitVisible(_:)) {
        self.window = window
        self.systemVisible = systemVisible
        self.events = events
        systemWatch = events?.subscribe(Self.systemNotice, owner: "WindowOcclusionFamily") { [weak self] in
            self?.systemDidChange()
        }
    }

    /// `window`'s family, made on first use and kept alive by the window. A later call returns the
    /// same family and ignores `events`.
    ///
    /// - Parameters:
    ///   - window: The window.
    ///   - events: The notices the family follows (default the window's shared ``WindowEvents``;
    ///     tests pass their own center's).
    public static func of(_ window: NSWindow, events: WindowEvents? = nil) -> WindowOcclusionFamily {
        if let existing = installed(on: window) { return existing }
        let family = WindowOcclusionFamily(window: window, events: events ?? WindowEvents.of(window))
        objc_setAssociatedObject(window, &associationKey, family, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return family
    }

    /// `window`'s family if one was made; nil makes nothing.
    public static func installed(on window: NSWindow) -> WindowOcclusionFamily? {
        objc_getAssociatedObject(window, &associationKey) as? WindowOcclusionFamily
    }

    // MARK: Reading

    /// AppKit's answer, read live: some of `window` is on screen (`occlusionState` contains
    /// `.visible`). False while it is minimized, on another Space, covered by other apps' windows or
    /// ordered out (the app hidden). The one read of `occlusionState` outside Debug files.
    public static func appKitVisible(_ window: NSWindow) -> Bool {
        window.occlusionState.contains(.visible)
    }

    /// AppKit's answer for the window now (false once the window is gone).
    public var isSystemVisible: Bool {
        guard let window else { return false }
        return systemVisible(window)
    }

    /// Some of the window can be seen: AppKit says so and the source does not say occluded.
    public var isOnScreen: Bool { !isOccluded && isSystemVisible }

    /// Whether some of `window` can be seen now: its family's ``isOnScreen``, or AppKit's answer for
    /// a window with no family (the source judges only windows with one). Makes no family.
    public static func isOnScreen(_ window: NSWindow) -> Bool {
        installed(on: window)?.isOnScreen ?? appKitVisible(window)
    }

    /// Calls `handler` with each of the app's windows that posts AppKit's occlusion notice, with or
    /// without a family, until the returned observation is released: for an owner that watches
    /// windows it does not own (the source, `WindowOcclusionChecker`; a window's Chromium page
    /// children; app-wide diagnostics). A window's own readers subscribe to its family instead.
    ///
    /// - Parameters:
    ///   - center: Where the windows post (tests pass their own).
    ///   - handler: Main-actor work, given the window.
    /// - Returns: The observation; keep it, releasing it stops observing.
    public static func observeSystemChanges(center: NotificationCenter = .default,
                                            _ handler: @escaping @MainActor (NSWindow) -> Void) -> MainActorObservation {
        MainActorObservation(systemNotice, center: center, read: { $0.object as? NSWindow }) { window in
            if let window { handler(window) }
        }
    }

    // MARK: Subscribing

    /// Calls `onChange` with ``isOccluded`` after each flip and each AppKit occlusion notice of the
    /// window, in `stage` order, until the returned subscription is cancelled or released. It is not
    /// called for the current value: read ``isOnScreen`` when subscribing. A notice may change
    /// nothing; the subscriber reads the family again and then does nothing.
    ///
    /// - Parameters:
    ///   - stage: When it hears a flip, relative to the other subscribers.
    ///   - owner: The subscriber's name for diagnostics.
    ///   - onChange: Main-actor work, given the new value.
    /// - Returns: The subscription; keep it, releasing it ends the subscription.
    public func subscribe(_ stage: Stage, owner: String,
                          _ onChange: @escaping @MainActor (Bool) -> Void) -> WindowOcclusionSubscription {
        let subscription = WindowOcclusionSubscription(stage: stage, owner: owner, onChange: onChange)
        subscriptions.removeAll { $0.subscription?.isActive != true }
        subscriptions.append(WeakSubscription(subscription: subscription))
        return subscription
    }

    /// Owners of the live subscriptions, in delivery order.
    public var subscribers: [String] { ordered().map(\.owner) }

    /// The source judged the window (its only caller): a flip tells every subscriber, content first.
    public func set(occluded: Bool) {
        guard occluded != isOccluded else { return }
        isOccluded = occluded
        flips += 1
        deliver()
    }

    /// The window posted AppKit's occlusion notice: every subscriber reads it again, content first.
    private func systemDidChange() {
        systemChanges += 1
        deliver()
    }

    private func deliver() {
        let occluded = isOccluded
        generation += 1
        let current = generation
        for subscription in ordered() {
            guard generation == current else { return }
            guard subscription.isActive else { continue }
            subscription.onChange(occluded)
        }
    }

    /// The live subscriptions by stage, each stage in subscription order.
    private func ordered() -> [WindowOcclusionSubscription] {
        subscriptions.removeAll { $0.subscription?.isActive != true }
        let live = subscriptions.compactMap(\.subscription)
        return Stage.allCases.flatMap { stage in live.filter { $0.stage == stage } }
    }

    private struct WeakSubscription {
        weak var subscription: WindowOcclusionSubscription?
    }
}

/// One ``WindowOcclusionFamily/subscribe(_:owner:_:)`` registration. The family holds it weakly:
/// releasing it ends the subscription and releases its closure; ``cancel()`` ends it early.
@MainActor public final class WindowOcclusionSubscription {
    let stage: WindowOcclusionFamily.Stage
    let owner: String
    let onChange: @MainActor (Bool) -> Void
    /// Whether ``cancel()`` has not been called.
    public private(set) var isActive = true

    init(stage: WindowOcclusionFamily.Stage, owner: String, onChange: @escaping @MainActor (Bool) -> Void) {
        self.stage = stage
        self.owner = owner
        self.onChange = onChange
    }

    /// Stops the subscription; later calls do nothing.
    public func cancel() { isActive = false }
}
