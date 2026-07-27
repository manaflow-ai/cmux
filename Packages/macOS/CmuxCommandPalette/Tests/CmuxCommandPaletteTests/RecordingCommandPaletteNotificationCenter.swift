import Foundation

// Test callbacks are invoked synchronously on MainActor; no state crosses concurrency domains.
final class RecordingCommandPaletteNotificationCenter: NotificationCenter, @unchecked Sendable {
    typealias AddedObserver = (
        name: Notification.Name?,
        objectID: ObjectIdentifier?,
        token: RecordingCommandPaletteObserverToken,
        block: @Sendable (Notification) -> Void
    )

    private(set) var addedObservers: [AddedObserver] = []
    private(set) var removedObserverIDs: [Int] = []

    override func addObserver(
        forName name: Notification.Name?,
        object obj: Any?,
        queue: OperationQueue?,
        using block: @escaping @Sendable (Notification) -> Void
    ) -> any NSObjectProtocol {
        let token = RecordingCommandPaletteObserverToken(id: addedObservers.count + 1)
        addedObservers.append((
            name: name,
            objectID: (obj as AnyObject?).map(ObjectIdentifier.init),
            token: token,
            block: block
        ))
        return token
    }

    override func removeObserver(_ observer: Any) {
        guard let token = observer as? RecordingCommandPaletteObserverToken else { return }
        removedObserverIDs.append(token.id)
    }

    func send(name: Notification.Name, object: AnyObject) {
        let objectID = ObjectIdentifier(object)
        for observer in addedObservers where
            observer.name == name && (observer.objectID == nil || observer.objectID == objectID) {
            observer.block(Notification(name: name, object: object))
        }
    }
}
