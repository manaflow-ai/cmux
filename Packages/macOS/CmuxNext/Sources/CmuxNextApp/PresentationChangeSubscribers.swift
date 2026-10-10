/// Who hears that `TabContentCache`'s presentation changed (a tab shown,
/// hidden or released). Each owner subscribes under its own name, so one
/// owner can never replace another's handler: before this, the cache had a
/// single closure property, and input verification replaced the one that
/// refreshed the browser host's tab list (cx-x3t9). Subscribing again under
/// the same name replaces only that owner's handler.
final class PresentationChangeSubscribers {
    private var subscribers: [(name: String, handler: () -> Void)] = []

    /// The subscriber names in notification order.
    var names: [String] { subscribers.map(\.name) }

    /// `handler` runs on every change, after the earlier subscribers.
    func subscribe(_ name: String, _ handler: @escaping () -> Void) {
        if let index = subscribers.firstIndex(where: { $0.name == name }) {
            subscribers[index].handler = handler
        } else {
            subscribers.append((name, handler))
        }
    }

    func notify() {
        for subscriber in subscribers { subscriber.handler() }
    }
}
