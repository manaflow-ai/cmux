public import CoreFoundation
public import CmuxNextCompat

/// Where an ``InputResponsePass`` puts its observer: the main run loop in the app
/// (``MainRunLoopBeforeCommit``), a fake run loop in tests.
@MainActor
public protocol InputResponseRunLoop {
    /// Adds a repeating observer at `order` of the stages where Core Animation commits (before
    /// waiting, and on exit); it runs until the token is invalidated.
    func observeBeforeCommit(order: CFIndex, _ handler: @escaping @MainActor () -> Void) -> any InputResponseObservation
}

/// An observer an ``InputResponseRunLoop`` added.
public protocol InputResponseObservation: AnyObject {
    /// Removes the observer; safe to call more than once, and from inside its own callout.
    func invalidate()
}

/// The main run loop's commit stages, before waiting and on exit (Core Animation's transaction
/// observer listens to both: a turn that handles an event and returns without waiting commits on
/// exit), in the common modes, so menu tracking and drags get the pass too.
@MainActor
public struct MainRunLoopBeforeCommit: InputResponseRunLoop {
    public nonisolated init() {}

    public func observeBeforeCommit(order: CFIndex, _ handler: @escaping @MainActor () -> Void) -> any InputResponseObservation {
        MainRunLoopObserver(activities: [.beforeWaiting, .exit], order: order) { _ in handler() }
    }
}

extension MainRunLoopObserver: InputResponseObservation {}
