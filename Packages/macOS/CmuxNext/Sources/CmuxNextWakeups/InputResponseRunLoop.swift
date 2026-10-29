public import CoreFoundation
public import CmuxNextCompat

/// Where an ``InputResponsePass`` puts its observer: the main run loop in the app
/// (``MainRunLoopBeforeCommit``), a fake run loop in tests.
@MainActor
public protocol InputResponseRunLoop {
    /// Adds a repeating observer at `order` of the stages where Core Animation commits (before
    /// waiting, and on exit); it runs until the token is invalidated.
    func observeBeforeCommit(order: CFIndex, _ handler: @escaping @MainActor () -> Void) -> any InputResponseObservation

    /// Runs `work` once on a later turn, before that turn's commit, and wakes the run loop for
    /// it (an observer never wakes it). Never inline.
    func perform(_ work: @escaping @MainActor () -> Void)
}

/// An observer an ``InputResponseRunLoop`` added.
public protocol InputResponseObservation: AnyObject {
    /// Removes the observer; safe to call more than once, and from inside its own callout.
    func invalidate()
}

/// The main run loop's commit stages, before waiting and on exit (Core Animation's transaction
/// observer listens to both: a turn that handles an event and returns without waiting commits on
/// exit), in the common modes, so menu tracking and drags get the pass too (the pass is on the run
/// loop from the start of the input's dispatch, before a nested loop's first wait).
@MainActor
public struct MainRunLoopBeforeCommit: InputResponseRunLoop {
    /// The main run loop's commit stages.
    public nonisolated init() {}

    /// Adds a repeating main run loop observer before waiting and on exit, in the common modes.
    public func observeBeforeCommit(order: CFIndex, _ handler: @escaping @MainActor () -> Void) -> any InputResponseObservation {
        MainRunLoopObserver(activities: [.beforeWaiting, .exit], order: order) { _ in handler() }
    }

    /// A block on the main run loop in the common modes: it runs at the blocks stage of the next
    /// turn, ahead of that turn's before-waiting commit.
    public func perform(_ work: @escaping @MainActor () -> Void) {
        MainRunLoopBlock.perform(work)
    }
}

extension MainRunLoopObserver: InputResponseObservation {}
