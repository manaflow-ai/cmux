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
/// ```swift
/// observation = MainActorObservation(NSWindow.didBecomeKeyNotification, object: window) { [weak self] in
///     self?.keyChanged()
/// }
/// ```
public final class MainActorObservation {
    private let center: NotificationCenter
    private let token: any NSObjectProtocol

    /// Observes `name` from `object` (nil: any sender) on `center`, delivering on the main actor.
    ///
    /// - Parameters:
    ///   - name: The notification to observe.
    ///   - object: Only notifications this object posts; nil for every sender.
    ///   - center: The center to observe (default `NotificationCenter.default`; tests pass their own).
    ///   - handler: Main-actor work for each notification (the `Notification` is not `Sendable`;
    ///     read what you need from the poster's state, not the payload).
    public init(
        _ name: Notification.Name,
        object: AnyObject? = nil,
        center: NotificationCenter = .default,
        _ handler: @escaping @MainActor () -> Void
    ) {
        self.center = center
        token = center.addObserver(forName: name, object: object, queue: MainQueueDelivery.queue) { _ in
            #if canImport(Darwin)
            // main-proof: the observer is registered on the main queue (queue: .main).
            MainActor.assumeIsolated { handler() }
            #else
            MainQueueDelivery.deliver { handler() }
            #endif
        }
    }

    /// Observes `name` and hands the main-actor handler the value `read` takes from each notification.
    ///
    /// `read` and `handler` both run inside this type's one main-delivery proof, on the same delivery,
    /// so the value may be any type, `Sendable` or not (an `NSMenu`, an `NSWindow`): no caller needs a
    /// box to carry it from the notification to the handler.
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
    ///   - atOnce: Delivers in the poster's own call (no queue), so the poster sees the handler's
    ///     effect before its post returns (a press that opens a menu, then checks a key loss); only a
    ///     post made on the main thread is delivered. False: on the main queue, after the post.
    ///   - read: Reads what the handler needs from the notification, on the main actor.
    ///   - handler: Main-actor work with the value `read` returned.
    public init<Value>(
        _ name: Notification.Name,
        object: AnyObject? = nil,
        center: NotificationCenter = .default,
        atOnce: Bool = false,
        read: @escaping @MainActor (Notification) -> Value,
        _ handler: @escaping @MainActor (Value) -> Void
    ) {
        self.center = center
        token = center.addObserver(forName: name, object: object, queue: atOnce ? nil : MainQueueDelivery.queue) { note in
            #if canImport(Darwin)
            guard Thread.isMainThread else { return } // main-proof: drops a post off the main thread (only `atOnce` can see one)
            // crash-allow: the center delivers on the main thread (queue: .main, or `atOnce` with the check above) and the notification is read only inside the assumeIsolated below, on this same delivery, so it never crosses actors.
            nonisolated(unsafe) let note = note
            // main-proof: delivered on the main thread: the main queue (queue: .main), or `atOnce` after the Thread.isMainThread check above.
            MainActor.assumeIsolated { handler(read(note)) }
            #else
            // A main-queue post reads the notification in this same call; a post from another thread hands this
            // copy (a struct) to the main queue and reads it there after the post, the handoff Darwin's
            // `queue: .main` makes: the center never touches the posted notification again.
            // crash-allow: one owner at a time: the posting call hands its copy to the main-queue read, nothing else holds it.
            nonisolated(unsafe) let note = note
            if atOnce {
                MainQueueDelivery.ifOnMain { handler(read(note)) } // drops a post off the main queue, as on Darwin
            } else {
                MainQueueDelivery.deliver { handler(read(note)) }
            }
            #endif
        }
    }

    /// Stops observing now (also happens when the token is released).
    public func cancel() {
        center.removeObserver(token)
    }

    deinit {
        center.removeObserver(token)
    }
}

extension MainQueueDelivery {
    /// The queue a main-actor observer registers on: the main queue on Darwin; none (the posting thread,
    /// handed to the main queue by `deliver`) on the non-Darwin Foundation, where a `.main` observer deadlocks.
    static var queue: OperationQueue? {
        #if canImport(Darwin)
        .main
        #else
        nil
        #endif
    }
}

#if canImport(Darwin)
enum MainQueueDelivery {}
#else
/// Main-queue delivery for the non-Darwin Foundation, where `addObserver(queue: .main)` deadlocks a post
/// made on the main actor: the main actor there can run on a thread that is not the main thread while it
/// drains the main queue, so the center sees another queue, enqueues on the main queue and waits for it.
/// A post made on the main queue runs the handler in the poster's call, as on Darwin; a post from elsewhere
/// runs it on the main queue after the post (this type's documented "on the main queue, after the post").
enum MainQueueDelivery {
    private static let key: DispatchSpecificKey<Bool> = {
        let key = DispatchSpecificKey<Bool>()
        DispatchQueue.main.setSpecific(key: key, value: true)
        return key
    }()

    static var isOnMainQueue: Bool { DispatchQueue.getSpecific(key: key) == true }

    static func deliver(_ body: @escaping @MainActor () -> Void) {
        if isOnMainQueue {
            // main-proof: running on the main queue (the specific key set on it above).
            MainActor.assumeIsolated { body() }
        } else {
            // Off the main queue: hand it to the main queue, after the post (no wait, so no main-queue deadlock).
            // main-async-allow: the non-Darwin NotificationCenter forces it: its `queue: .main` deadlocks a main-actor post, and MainDelivery sits in CmuxNextWakeups, above this module.
            // main-proof: DispatchQueue.main.async runs the block on the main queue.
            DispatchQueue.main.async { MainActor.assumeIsolated { body() } }
        }
    }

    static func ifOnMain(_ body: @MainActor () -> Void) {
        guard isOnMainQueue else { return }
        // main-proof: running on the main queue (the specific key set on it above).
        MainActor.assumeIsolated { body() }
    }
}
#endif
