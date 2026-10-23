public import Foundation

/// An observer of the main run loop whose handler runs on the main actor and that removes
/// itself when released.
///
/// It replaces the hand-written pair `CFRunLoopObserverCreateWithHandler(...)`, whose handler
/// asserts the main actor with `assumeIsolated`, plus `CFRunLoopAddObserver(CFRunLoopGetMain(),
/// ...)`: the main-thread proof lives here once, and the owner's `deinit` needs nothing
/// (`CFRunLoopObserverInvalidate` is thread-safe, so no isolated `deinit`, which macOS 14
/// cannot back-deploy). Keep the token in a stored property; set it to nil or call
/// ``invalidate()`` to stop early.
///
/// ```swift
/// keeper = MainRunLoopObserver(activities: .beforeWaiting, order: .max) { _ in
///     ArrowCursorView.keepCursor()
/// }
/// ```
public nonisolated final class MainRunLoopObserver {
    private let observer: CFRunLoopObserver

    /// Adds an observer of `activities` to the main run loop in `modes`, from any thread.
    ///
    /// - Parameters:
    ///   - activities: The run loop stages that call `handler` (for example `.beforeWaiting`,
    ///     which runs only in passes that other work started and never wakes the run loop).
    ///   - repeats: False to call `handler` once, at the first matching stage; the run loop
    ///     then removes the observer. Default true.
    ///   - order: Where `handler` runs among the observers of the same stage, lowest first.
    ///     `.max` runs after every other observer of the stage, Core Animation's commit (and
    ///     with it AppKit's display cycle) included. Default 0.
    ///   - modes: The run loop mode to observe (default `.commonModes`, which includes the
    ///     default mode and the event-tracking mode of menus and drags).
    ///   - handler: Main-actor work with the stage that called it.
    public init(
        activities: CFRunLoopActivity,
        repeats: Bool = true,
        order: CFIndex = 0,
        modes: CFRunLoopMode = .commonModes,
        _ handler: @escaping @MainActor (CFRunLoopActivity) -> Void
    ) {
        observer = CFRunLoopObserverCreateWithHandler(nil, activities.rawValue, repeats, order) { _, activity in
            // main-proof: the observer is added only to CFRunLoopGetMain(), whose observers run on the main thread.
            MainActor.assumeIsolated { handler(activity) }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, modes)
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
}
