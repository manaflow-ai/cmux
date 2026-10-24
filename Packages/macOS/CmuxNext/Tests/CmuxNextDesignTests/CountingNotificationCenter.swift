import Foundation

/// A notification center that counts the observers registered on it now, by name: a test reads how
/// many times the code under test listens for one notice (once per app, or once per window).
// Test-only center; `lock` guards both tables (an observer token can be released on any thread).
nonisolated final class CountingNotificationCenter: NotificationCenter, @unchecked Sendable {
    private let lock = NSLock()
    private var live: [Notification.Name: Int] = [:]
    private var names: [ObjectIdentifier: Notification.Name] = [:]

    /// The observers of `name` registered now.
    func observers(of name: Notification.Name) -> Int {
        lock.withLock { live[name, default: 0] }
    }

    override func addObserver(forName name: NSNotification.Name?, object obj: Any?, queue: OperationQueue?,
                              using block: @escaping @Sendable (Notification) -> Void) -> any NSObjectProtocol {
        let token = super.addObserver(forName: name, object: obj, queue: queue, using: block)
        if let name {
            lock.withLock {
                live[name, default: 0] += 1
                names[ObjectIdentifier(token)] = name
            }
        }
        return token
    }

    override func removeObserver(_ observer: Any) {
        lock.withLock {
            if let name = names.removeValue(forKey: ObjectIdentifier(observer as AnyObject)) {
                live[name, default: 0] -= 1
            }
        }
        super.removeObserver(observer)
    }
}
