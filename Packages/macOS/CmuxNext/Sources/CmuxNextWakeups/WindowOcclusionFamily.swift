public import AppKit
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
/// One per window, made on first use and kept alive by the window (``of(_:)``), as
/// ``WindowEvents`` and the window's ``FrameScheduler`` are.
///
/// Subscribers hear each flip in ``Stage`` order: the content producers first (the window's
/// ``FrameScheduler`` pauses its frame clients, Ghostty surfaces stop drawing, hosted pages are
/// told `occluded`, loops come off), then diagnostics, so a diagnostic never reads a window that is
/// half paused.
///
/// ```swift
/// let family = WindowOcclusionFamily.of(window)
/// watch = family.subscribe(.content, owner: "TerminalSurfaceView") { [weak self] _ in self?.updateOcclusion() }
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

    private var subscriptions: [WeakSubscription] = []
    /// Counts flips: a delivery stops when a subscriber's reaction started a newer one.
    private var generation = 0

    private static var associationKey: UInt8 = 0

    /// A family of `window` that is not installed on it (tests; the app uses ``of(_:)``).
    public init(window: NSWindow) {
        self.window = window
    }

    /// `window`'s family, made on first use and kept alive by the window.
    public static func of(_ window: NSWindow) -> WindowOcclusionFamily {
        if let existing = installed(on: window) { return existing }
        let family = WindowOcclusionFamily(window: window)
        objc_setAssociatedObject(window, &associationKey, family, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return family
    }

    /// `window`'s family if one was made; nil makes nothing.
    public static func installed(on window: NSWindow) -> WindowOcclusionFamily? {
        objc_getAssociatedObject(window, &associationKey) as? WindowOcclusionFamily
    }

    /// Calls `onChange` with ``isOccluded`` after each flip, in `stage` order, until the returned
    /// subscription is cancelled or released. It is not called for the current value: read
    /// ``isOccluded`` when subscribing.
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
