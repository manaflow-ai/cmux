import Foundation
package import UserNotifications

/// The daemon-backed `UNUserNotificationCenter` calls the banners make. `SystemNotificationCenter` is the
/// system center; tests replace it with a recorder.
package nonisolated protocol NotificationCenterBackend: Sendable {
    /// Adds banner `request`; `completion` gets the center's error, if any.
    func post(_ request: UNNotificationRequest, completion: @escaping @Sendable ((any Error)?) -> Void)
    /// Removes banners `ids`, shown or still queued.
    func withdraw(_ ids: [String])
    /// Removes every banner of this app, shown or still queued.
    func withdrawAll()
    func install(categories: Set<UNNotificationCategory>)
    func askAuthorization(_ options: UNAuthorizationOptions, completion: @escaping @Sendable (Bool) -> Void)
    /// The ids of this app's banners in Notification Center, then those still queued.
    func bannerIDs(completion: @escaping @Sendable (_ delivered: [String], _ pending: [String]) -> Void)
}

/// Runs every daemon-backed `UNUserNotificationCenter` call on one serial utility queue, never on the main
/// thread. UserNotifications enters one internal connection queue synchronously for each of these calls and
/// waits there on `usernoted`; with `usernoted` slow or wedged, a removal made on the main thread froze the
/// app for minutes, and an add waits behind a stuck removal
/// (https://github.com/manaflow-ai/cmux/issues/47009). A wedged `usernoted` now delays or drops banners and
/// nothing else. The serial queue keeps the calls in the order the app made them (categories before the
/// first banner, a banner before its withdrawal).
package nonisolated final class NotificationCenterQueue: Sendable {
    private let backend: any NotificationCenterBackend
    private let queue = DispatchQueue(label: "com.cmuxterm.app.next.notifications", qos: .utility)

    package init(backend: any NotificationCenterBackend) {
        self.backend = backend
    }

    package func post(_ request: UNNotificationRequest, completion: @escaping @Sendable ((any Error)?) -> Void) {
        let request = NotificationCenterHandoff(value: request)
        queue.async { [backend] in backend.post(request.value, completion: completion) }
    }

    package func withdraw(_ ids: [String]) {
        queue.async { [backend] in backend.withdraw(ids) }
    }

    package func withdrawAll() {
        queue.async { [backend] in backend.withdrawAll() }
    }

    package func install(categories: Set<UNNotificationCategory>) {
        let categories = NotificationCenterHandoff(value: categories)
        queue.async { [backend] in backend.install(categories: categories.value) }
    }

    package func askAuthorization(_ options: UNAuthorizationOptions, completion: @escaping @Sendable (Bool) -> Void) {
        queue.async { [backend] in backend.askAuthorization(options, completion: completion) }
    }

    package func bannerIDs() async -> (delivered: [String], pending: [String]) {
        await withCheckedContinuation { continuation in
            queue.async { [backend] in
                backend.bannerIDs { delivered, pending in continuation.resume(returning: (delivered, pending)) }
            }
        }
    }

    /// Returns once every call made before it has gone to the backend (tests).
    package func drained() async {
        await withCheckedContinuation { continuation in queue.async { continuation.resume() } }
    }
}

/// A banner request or category set built on the main actor and only read on the queue after that.
// crash-allow: each value is a fresh UNNotificationRequest or Set<UNNotificationCategory> (immutable NSSecureCoding objects) that the sender never touches after the handoff, so the queue is its only reader
private nonisolated struct NotificationCenterHandoff<Value>: @unchecked Sendable {
    let value: Value
}

/// The system center, read on the queue for each call (`UNUserNotificationCenter.current()` is the one
/// shared center; the main actor only sets its delegate).
package nonisolated struct SystemNotificationCenter: NotificationCenterBackend {
    package init() {}

    package func post(_ request: UNNotificationRequest, completion: @escaping @Sendable ((any Error)?) -> Void) {
        UNUserNotificationCenter.current().add(request, withCompletionHandler: completion)
    }

    package func withdraw(_ ids: [String]) {
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: ids)
        center.removePendingNotificationRequests(withIdentifiers: ids)
    }

    package func withdrawAll() {
        let center = UNUserNotificationCenter.current()
        center.removeAllDeliveredNotifications()
        center.removeAllPendingNotificationRequests()
    }

    package func install(categories: Set<UNNotificationCategory>) {
        UNUserNotificationCenter.current().setNotificationCategories(categories)
    }

    package func askAuthorization(_ options: UNAuthorizationOptions, completion: @escaping @Sendable (Bool) -> Void) {
        UNUserNotificationCenter.current().requestAuthorization(options: options) { granted, _ in completion(granted) }
    }

    package func bannerIDs(completion: @escaping @Sendable (_ delivered: [String], _ pending: [String]) -> Void) {
        UNUserNotificationCenter.current().getDeliveredNotifications { delivered in
            let deliveredIDs = delivered.map(\.request.identifier)
            UNUserNotificationCenter.current().getPendingNotificationRequests { pending in
                completion(deliveredIDs, pending.map(\.identifier))
            }
        }
    }
}
