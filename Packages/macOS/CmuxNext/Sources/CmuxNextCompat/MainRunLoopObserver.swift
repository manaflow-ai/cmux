public import Foundation

/// An observer of the main run loop whose handler runs on the main actor and that removes
/// itself when released.
///
/// It replaces the hand-written pair `CFRunLoopObserverCreateWithHandler(...)`, whose handler
/// asserts the main actor with `assumeIsolated`, plus `CFRunLoopAddObserver(CFRunLoopGetMain(),
/// ...)`: the main-thread proof lives here once, and the owner's `deinit` needs nothing
/// (`CFRunLoopObserverInvalidate` is thread-safe, so no isolated `deinit`, which macOS 14
/// cannot back-deploy). Keep the token in a stored property; set it to nil or call
/// ``invalidate()`` to stop early. For work that runs once and has no owner to stop it, use
/// ``once(activities:order:mode:_:)``, which needs no token.
///
/// An observer never wakes the main run loop. Its handler runs at the first matching stage of
/// a pass that other work starts (an event, a timer, a queued block, a display cycle). "From
/// any thread" below means only that adding, invalidating and releasing an observer are
/// thread-safe, not that the handler runs soon: added off the main thread while the main run
/// loop sleeps, it waits for unrelated main-thread work, for as long as that takes. For work
/// from off the main thread that must run promptly, use ``MainRunLoopBlock/perform(mode:_:)``,
/// which wakes the run loop.
///
/// ```swift
/// keeper = MainRunLoopObserver(activities: .beforeWaiting, order: .max) { _ in
///     ArrowCursorView.keepCursor()
/// }
/// ```
///
/// The main run loop keeps the observer, and with it the handler, until the token is released
/// or invalidated. So a handler must capture the token's owner weakly (`[weak self]`): a strong
/// capture makes a cycle (owner, token, observer, handler, owner), the owner never deinits, and
/// the handler runs on every pass forever.
///
/// ```swift
/// final class FrameWatcher {
///     private var observer: MainRunLoopObserver?
///
///     func start() {
///         observer = MainRunLoopObserver(activities: .beforeWaiting) { [weak self] _ in
///             self?.frameDidPass()
///         }
///     }
///
///     func frameDidPass() {}
/// }
/// ```
public nonisolated final class MainRunLoopObserver {
    private let observer: CFRunLoopObserver

    /// Adds an observer of `activities` to the main run loop in `mode`, from any thread.
    ///
    /// It does not wake the main run loop: the first call comes at a matching stage of a pass
    /// that other work starts (see the type's discussion).
    ///
    /// - Parameters:
    ///   - activities: The run loop stages that call `handler` (for example `.beforeWaiting`,
    ///     which runs only in passes that other work started and never wakes the run loop).
    ///   - repeats: False to call `handler` once, at the first matching stage; the run loop
    ///     then removes the observer. Default true.
    ///   - order: Where `handler` runs among the observers of the same stage, lowest first.
    ///     `.max` runs after every other observer of the stage, Core Animation's commit (and
    ///     with it AppKit's display cycle) included. Default 0.
    ///   - mode: The run loop mode to observe (default `.commonModes`, which includes the
    ///     default mode and the event-tracking mode of menus and drags).
    ///   - handler: Main-actor work with the stage that called it.
    public init(
        activities: CFRunLoopActivity,
        repeats: Bool = true,
        order: CFIndex = 0,
        mode: CFRunLoopMode = .commonModes,
        _ handler: @escaping @MainActor (CFRunLoopActivity) -> Void
    ) {
        observer = Self.addMainObserver(activities: activities, repeats: repeats, order: order, mode: mode, handler)
    }

    /// Calls `body` once on the main actor, at the main run loop's next stage in `activities`,
    /// from any thread. The call returns no token: the run loop keeps the observer until that
    /// one call, then removes it, so the work cannot be cancelled.
    ///
    /// It does not wake the main run loop. Called on the main thread, `body` runs when the
    /// pass in progress reaches that stage. If it is called inside a callout of a stage in
    /// `activities` (for example from AppKit's display cycle or a Core Animation commit at
    /// `.beforeWaiting`), `body` runs at that stage of the next pass, which other work must
    /// start: the run loop collects a stage's observers before it calls them, so an observer
    /// added during that stage misses the current pass. Called off the main thread while the
    /// main run loop sleeps, `body` waits for a pass that other work starts; use
    /// ``MainRunLoopBlock/perform(mode:_:)`` for work that must run promptly.
    ///
    /// ```swift
    /// // After AppKit's display and Core Animation's commit of the current pass.
    /// MainRunLoopObserver.once(activities: .beforeWaiting, order: .max) { startDeferredWork() }
    /// ```
    ///
    /// - Parameters:
    ///   - activities: The run loop stages, the first of which calls `body`.
    ///   - order: Where `body` runs among the observers of the same stage, lowest first (see
    ///     ``init(activities:repeats:order:mode:_:)``). Default 0.
    ///   - mode: The run loop mode to observe (default `.commonModes`).
    ///   - body: The main-actor work.
    public static func once(
        activities: CFRunLoopActivity,
        order: CFIndex = 0,
        mode: CFRunLoopMode = .commonModes,
        _ body: @escaping @MainActor () -> Void
    ) {
        _ = addMainObserver(activities: activities, repeats: false, order: order, mode: mode) { _ in body() }
    }

    /// Whether the observer still calls its handler (false after ``invalidate()``, or after
    /// the one call of an observer that does not repeat).
    public var isValid: Bool { CFRunLoopObserverIsValid(observer) }

    /// Stops observing now and removes the observer from the main run loop (also happens when
    /// the token is released). Safe to call more than once and from any thread.
    public func invalidate() {
        CFRunLoopObserverInvalidate(observer)
    }

    deinit {
        CFRunLoopObserverInvalidate(observer)
    }

    /// Makes an observer whose handler runs on the main actor and adds it to the main run loop
    /// in `mode`: the one main-thread proof of this type.
    private static func addMainObserver(
        activities: CFRunLoopActivity,
        repeats: Bool,
        order: CFIndex,
        mode: CFRunLoopMode,
        _ handler: @escaping @MainActor (CFRunLoopActivity) -> Void
    ) -> CFRunLoopObserver {
        let observer: CFRunLoopObserver = CFRunLoopObserverCreateWithHandler(nil, activities.rawValue, repeats, order) { _, activity in
            // main-proof: the observer is added only to CFRunLoopGetMain(), whose observers run on the main thread.
            MainActor.assumeIsolated { handler(activity) }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, mode)
        return observer
    }
}
