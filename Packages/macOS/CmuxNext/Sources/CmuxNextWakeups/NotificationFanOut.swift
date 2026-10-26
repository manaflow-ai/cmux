import Foundation
import CmuxNextCompat

/// One NotificationCenter observer per name for one sender (a window) or every sender (the app),
/// fanned out to its subscribers by their nodes' visibility: the shared core of ``WindowEvents``
/// and ``AppEvents``. Chromium observes an NSWindow once per widget and fans out through the
/// widget's observer list (`components/remote_cocoa/app_shim/views_nswindow_delegate.mm`,
/// `ui/views/widget/widget.cc` `observers_`), not once per view.
@MainActor final class NotificationFanOut {
    private struct Entry {
        let delivery: EventDelivery
        weak var node: VisibilityNode?
        let handler: @MainActor (EventCall) -> Void
    }

    private final class Channel {
        let observation: MainActorObservation
        var entries: [UInt64: Entry] = [:]

        init(observation: MainActorObservation) {
            self.observation = observation
        }
    }

    /// The deferred-work key of one subscription's missed call on its node.
    private struct MissedKey: Hashable {
        let fanOut: ObjectIdentifier
        let id: UInt64
    }

    /// Held weakly: ``AppEvents/of(_:)`` hangs this fan-out on the center.
    private weak var center: NotificationCenter?
    /// The one sender observed; nil with ``scoped`` false observes every sender.
    private weak var object: AnyObject?
    private let scoped: Bool
    private var channels: [Notification.Name: Channel] = [:]
    private var nextID: UInt64 = 0
    private var deliveryCounts: [Notification.Name: Int] = [:]

    /// - Parameters:
    ///   - object: The only sender observed, held weakly; nil observes every sender.
    ///   - center: Where the notifications are posted.
    init(object: AnyObject?, center: NotificationCenter) {
        self.object = object
        self.scoped = object != nil
        self.center = center
    }

    func subscribe(_ name: Notification.Name, node: VisibilityNode?, delivery: EventDelivery, owner: String,
                   _ handler: @escaping @MainActor (EventCall) -> Void) -> EventSubscription {
        // A closed window posts nothing more; observing nil would hear every window.
        guard let center, !scoped || object != nil else { return EventSubscription(owner: owner, fanOut: nil, name: name, id: 0) }
        nextID &+= 1
        let id = nextID
        let channel = channels[name] ?? open(name, on: center)
        channel.entries[id] = Entry(delivery: delivery, node: node, handler: handler)
        return EventSubscription(owner: owner, fanOut: self, name: name, id: id)
    }

    func remove(_ name: Notification.Name, id: UInt64) {
        guard let channel = channels[name], let entry = channel.entries.removeValue(forKey: id) else { return }
        entry.node?.cancelDeferred(key: MissedKey(fanOut: ObjectIdentifier(self), id: id))
        // The last subscriber left: release the observation, which removes the observer.
        if channel.entries.isEmpty { channels[name] = nil }
    }

    /// Whether a NotificationCenter observer for `name` exists.
    func isObserving(_ name: Notification.Name) -> Bool { channels[name] != nil }

    /// How many subscriptions to `name` are live.
    func subscriberCount(_ name: Notification.Name) -> Int { channels[name]?.entries.count ?? 0 }

    /// How many times the center delivered `name` to this fan-out: one per post, however many
    /// subscribers, while it observes.
    func deliveries(_ name: Notification.Name) -> Int { deliveryCounts[name] ?? 0 }

    private func open(_ name: Notification.Name, on center: NotificationCenter) -> Channel {
        let observation = MainActorObservation(name, object: object, center: center) { [weak self] in
            self?.deliver(name)
        }
        let channel = Channel(observation: observation)
        channels[name] = channel
        return channel
    }

    private func deliver(_ name: Notification.Name) { // perf-hot: 0.1ms cmd-tab (one call per post, O(subscribers to the name))
        deliveryCounts[name, default: 0] += 1
        guard let channel = channels[name] else { return }
        // A handler may subscribe or cancel: walk a copy and skip the entries that left.
        for (id, entry) in channel.entries {
            guard channels[name]?.entries[id] != nil else { continue }
            if entry.delivery == .always {
                entry.handler(.posted)
            } else if let node = entry.node {
                if node.isVisible {
                    entry.handler(.posted)
                } else {
                    node.deferUntilVisible(key: MissedKey(fanOut: ObjectIdentifier(self), id: id)) { [weak self] in
                        self?.deliverMissed(name, id: id)
                    }
                }
            }
        }
    }

    private func deliverMissed(_ name: Notification.Name, id: UInt64) {
        guard let entry = channels[name]?.entries[id] else { return }
        entry.handler(.missed)
    }
}
