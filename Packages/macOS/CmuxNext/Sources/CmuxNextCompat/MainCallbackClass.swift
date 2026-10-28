/// The class a main-thread helper's callback runs in (plans/cmux-next/chrome-parity/p04-input.md,
/// task 080): ``MainActorObservation`` and ``MainRunLoopBlock`` take one, so a notification or a
/// run-loop block reaches the app's main-thread scheduler with a declared class and owner instead of
/// running as an unclassed callout beside a person's input.
///
/// CmuxNextCompat has no scheduler, so the classed values come from CmuxNextWakeups
/// (`MainWorkScheduler.callbackClass(_:owner:)`): input and frame callbacks run at once as tasks of
/// their class, and userBlocking, visible, automation and background ones wait behind work of their
/// class queued before them and the frame budget. Chrome posts every UI-thread task with its
/// queue's type the same way (`content/browser/scheduler/browser_task_queues.h`).
///
/// ``immediate`` runs the callback in the callout itself, as before this type existed. It is the
/// helpers' default only until the call sites name a class (tasks 081 and 082); new code passes one.
///
/// ```swift
/// observation = MainActorObservation(NSWindow.didBecomeKeyNotification, object: window,
///                                    class: mainWork.callbackClass(.visible, owner: "window.key")) { [weak self] in
///     self?.keyChanged()
/// }
/// ```
public nonisolated struct MainCallbackClass: Sendable {
    /// Runs or posts a callback the helper got on the main thread; nil: ``immediate``.
    private let deliver: (@MainActor @Sendable (_ body: @escaping @MainActor () -> Void) -> Void)?

    /// A classed delivery.
    ///
    /// - Parameter deliver: Gets each callback on the main thread, inside the helper's callout, and
    ///   runs it in its class: at once for input and frame work, and for other work with nothing held
    ///   or queued ahead of it that its class lets run; else held or queued for a later turn or frame.
    public init(deliver: @escaping @MainActor @Sendable (_ body: @escaping @MainActor () -> Void) -> Void) {
        self.deliver = deliver
    }

    private init() {
        deliver = nil
    }

    /// The callback runs in the helper's callout, with no class (the helpers' default until their
    /// call sites name one).
    public static let immediate = MainCallbackClass()

    /// Whether the callback runs in the callout itself.
    public var isImmediate: Bool { deliver == nil }

    /// Runs `body` in this class: now for ``immediate``, else through the class's delivery.
    @MainActor
    public func run(_ body: @escaping @MainActor () -> Void) {
        guard let deliver else { return body() }
        deliver(body)
    }
}
