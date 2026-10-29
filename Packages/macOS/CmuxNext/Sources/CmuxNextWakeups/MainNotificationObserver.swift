import CmuxNextCompat
public import Foundation

/// A NotificationCenter observer whose handler runs in a declared ``MainWorkClass`` on the app's
/// main-thread scheduler (plans/cmux-next/chrome-parity/p04-input.md, task 080), and that removes
/// itself when released.
///
/// It is ``MainActorObservation`` with the scheduler's class
/// (``MainWorkScheduler/callbackClass(_:owner:file:line:)``): an input or frame handler runs in the
/// notification's delivery, as a task of its class on the board; any other runs when its class's
/// budget lets it, in that delivery when nothing is queued ahead of it, else in a later turn or frame.
/// Use it instead of `addObserver(forName:object:queue: .main)` and instead of a
/// ``MainActorObservation`` with no class.
///
/// ```swift
/// observer = MainNotificationObserver(NSApplication.didChangeScreenParametersNotification, class: .visible,
///                                     owner: "screens.changed", on: mainWork) { [weak self] in
///     self?.relayout()
/// }
/// ```
@MainActor
public final class MainNotificationObserver {
    private let observation: MainActorObservation

    /// Observes `name` from `object` (nil: any sender) on `center`; `handler` runs in `workClass`.
    ///
    /// - Parameters:
    ///   - name: The notification to observe.
    ///   - object: Only notifications this object posts; nil for every sender.
    ///   - center: The center to observe (default `NotificationCenter.default`; tests pass their own).
    ///   - workClass: The class the handler runs in.
    ///   - owner: The handler's owner in the board, the watchdog's records and signposts.
    ///   - work: The app's main-thread scheduler.
    ///   - file: The observing file (leave the default).
    ///   - line: The observing line (leave the default).
    ///   - handler: Main-actor work for each notification (read what you need from the poster's
    ///     state, or use ``init(_:object:center:class:owner:on:file:line:read:_:)``).
    public convenience init(_ name: Notification.Name, object: AnyObject? = nil,
                            center: NotificationCenter = .default, class workClass: MainWorkClass, owner: String, on work: MainWorkScheduler,
                            file: StaticString = #fileID, line: UInt = #line, _ handler: @escaping @MainActor () -> Void) {
        self.init(name, object: object, center: center, class: workClass, owner: owner, on: work, file: file, line: line,
                  read: { _ in () }) { _ in handler() }
    }

    /// Observes `name` and hands the handler the value `read` takes from each notification, in the
    /// notification's delivery; `handler` runs in `workClass`.
    ///
    /// - Parameters:
    ///   - name: The notification to observe.
    ///   - object: Only notifications this object posts; nil for every sender.
    ///   - center: The center to observe.
    ///   - workClass: The class the handler runs in.
    ///   - owner: The handler's owner in the board, the watchdog's records and signposts.
    ///   - work: The app's main-thread scheduler.
    ///   - file: The observing file (leave the default).
    ///   - line: The observing line (leave the default).
    ///   - read: Reads what the handler needs from the notification, in its delivery.
    ///   - handler: Main-actor work with the value `read` returned.
    public init<Value>(_ name: Notification.Name, object: AnyObject? = nil,
                       center: NotificationCenter = .default, class workClass: MainWorkClass, owner: String, on work: MainWorkScheduler,
                       file: StaticString = #fileID, line: UInt = #line,
                       read: @escaping @MainActor (Notification) -> Value, _ handler: @escaping @MainActor (Value) -> Void) {
        observation = MainActorObservation(name, object: object, center: center,
                                           class: work.callbackClass(workClass, owner: owner, file: file, line: line),
                                           read: read, handler)
    }

    /// Stops observing now, and drops the deliveries still waiting in the class: a queued
    /// handler never runs after this (also happens when the observer is released).
    public func cancel() {
        observation.cancel()
    }
}
