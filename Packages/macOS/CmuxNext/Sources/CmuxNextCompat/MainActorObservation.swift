public import Foundation

/// A NotificationCenter observer whose handler runs on the main actor and that removes itself
/// when released.
///
/// It replaces the hand-written pair `addObserver(forName:object:queue: .main) { MainActor
/// .assumeIsolated { ... } }` plus `deinit { MainActor.assumeIsolated { removeObserver } }`:
/// the main-delivery proof lives here once, and the owner's `deinit` needs nothing
/// (`NotificationCenter.removeObserver(_:)` is thread-safe, so no isolated `deinit`, which
/// macOS 14 cannot back-deploy). Keep the token in a stored property; set it to nil or call
/// ``cancel()`` to stop early.
///
/// The handler runs in a ``MainCallbackClass``: pass one from the app's main-thread
/// scheduler so the notification's work is posted with a class and an owner and waits behind a
/// person's pending input. The default, ``MainCallbackClass/immediate``, runs it in the
/// notification's callout with no class; it stays only until the call sites name a class (tasks 081
/// and 082), and new code passes one.
///
/// ```swift
/// observation = MainActorObservation(NSWindow.didBecomeKeyNotification, object: window,
///                                    class: mainWork.callbackClass(.visible, owner: "window.key")) { [weak self] in
///     self?.keyChanged()
/// }
/// ```
public final class MainActorObservation {
    private let center: NotificationCenter
    private let token: any NSObjectProtocol
    /// Lives as long as the observation delivers: a handler that waits in its class runs only while
    /// this lives, so ``cancel()`` and release also drop the deliveries not run yet.
    private var alive: Alive?

    /// Observes `name` from `object` (nil: any sender) on `center`, delivering on the main actor.
    ///
    /// - Parameters:
    ///   - name: The notification to observe.
    ///   - object: Only notifications this object posts; nil for every sender.
    ///   - center: The center to observe (default `NotificationCenter.default`; tests pass their own).
    ///   - workClass: The class the handler runs in (default ``MainCallbackClass/immediate``: in the
    ///     notification's callout, with no class).
    ///   - work: Main-actor work for each notification (the `Notification` is not `Sendable`;
    ///     read what you need from the poster's state, not the payload).
    public init(
        _ name: Notification.Name,
        object: AnyObject? = nil,
        center: NotificationCenter = .default, class workClass: MainCallbackClass = .immediate,
        _ work: @escaping @MainActor () -> Void
    ) {
        self.center = center
        let alive = Alive()
        self.alive = alive
        let handler: @MainActor () -> Void = { [weak alive] in
            workClass.run { [weak alive] in if alive != nil { work() } }
        }
        // raw-observer-allow: the one Compat observer adapter, for notices WindowEvents and AppEvents do not carry
        token = center.addObserver(forName: name, object: object, queue: .main) { _ in
            // main-proof: the observer is registered on the main queue (queue: .main).
            MainActor.assumeIsolated { handler() }
        }
    }

    /// Observes `name` and hands the main-actor handler the value `read` takes from each notification.
    ///
    /// `read` runs inside this type's one main-delivery proof, on the notification's own delivery, and
    /// the handler gets its value on the main actor (in that delivery, or later in `workClass`), so the
    /// value may be any type, `Sendable` or not (an `NSMenu`, an `NSWindow`): no caller needs a box to
    /// carry it from the notification to the handler.
    ///
    /// ```swift
    /// MainActorObservation(NSMenu.didBeginTrackingNotification, read: { $0.object as? NSMenu }) { menu in
    ///     self.tracked = menu
    /// }
    /// ```
    ///
    /// - Parameters:
    ///   - name: The notification to observe.
    ///   - object: Only notifications this object posts; nil for every sender.
    ///   - center: The center to observe.
    ///   - workClass: The class the handler runs in (default ``MainCallbackClass/immediate``).
    ///     `read` always runs in the notification's callout.
    ///   - read: Reads what the handler needs from the notification, on the main actor.
    ///   - work: Main-actor work with the value `read` returned.
    public init<Value>(
        _ name: Notification.Name,
        object: AnyObject? = nil,
        center: NotificationCenter = .default, class workClass: MainCallbackClass = .immediate,
        read: @escaping @MainActor (Notification) -> Value,
        _ work: @escaping @MainActor (Value) -> Void
    ) {
        self.center = center
        let alive = Alive()
        self.alive = alive
        let handler: @MainActor (Value) -> Void = { [weak alive] value in
            workClass.run { [weak alive] in if alive != nil { work(value) } }
        }
        // raw-observer-allow: the one Compat observer adapter, for notices WindowEvents and AppEvents do not carry
        token = center.addObserver(forName: name, object: object, queue: .main) { note in
            // crash-allow: the center delivers on the main queue (queue: .main) and the notification is read only inside the assumeIsolated below, on this same delivery, so it never crosses actors.
            nonisolated(unsafe) let note = note
            // main-proof: the observer is registered on the main queue (queue: .main).
            MainActor.assumeIsolated { handler(read(note)) }
        }
    }

    /// Stops observing now, and drops the deliveries still waiting in their class (also happens
    /// when the observation is released).
    public func cancel() {
        alive = nil
        center.removeObserver(token)
    }

    deinit {
        center.removeObserver(token)
    }
}

/// The lifetime a waiting delivery checks (``MainActorObservation``). It holds no state, only its
/// identity for the weak references the deliveries keep, so it is `Sendable`: the main-actor
/// handlers capture it without sending a non-Sendable value into the main actor's region.
private final class Alive: Sendable {}
