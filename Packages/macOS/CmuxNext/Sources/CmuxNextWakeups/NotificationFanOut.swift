import Foundation
import CmuxNextCompat

/// One NotificationCenter observer per name for one sender (a window) or every sender (the app),
/// fanned out to its subscribers by their nodes' visibility: the shared core of ``WindowEvents``
/// and ``AppEvents``. Chromium observes an NSWindow once per widget and fans out through the
/// widget's observer list (`components/remote_cocoa/app_shim/views_nswindow_delegate.mm`,
/// `ui/views/widget/widget.cc` `observers_`), not once per view. Like that list
/// (`base/observer_list.h`), subscribers are called in the order they subscribed.
///
/// An ``EventDelivery/whenVisible`` subscriber whose node does not render (it is not visible and no
/// capture vote holds it, ``VisibilityNode/wantsFrames``) is marked missed on its first post only;
/// each node then holds one deferred call for this fan-out, which calls the node's missed
/// subscribers in the order they were marked when it renders again. A later post meanwhile costs
/// one flag check per such subscriber.
@MainActor final class NotificationFanOut {
    private struct Entry {
        let id: UInt64
        let delivery: EventDelivery
        weak var node: VisibilityNode?
        let handler: @MainActor (EventCall) -> Void
        /// A post arrived while the node did not render; its missed call is pending.
        var missed = false
    }

    /// One name's subscribers in subscription order. Ids grow, so `slots` stays sorted by id;
    /// a removed subscriber leaves a nil slot, compacted once the holes outnumber the live ones.
    private final class Channel {
        let observation: MainActorObservation
        private(set) var slots: [Entry?] = []
        private var index: [UInt64: Int] = [:]
        #if DEBUG || CMUX_BENCH_HOOKS
        /// The observer's record in the arm census, on a fan-out made with an observer ledger.
        var census = ArmCensusEntry()
        #endif

        init(observation: MainActorObservation) {
            self.observation = observation
        }

        var count: Int { index.count }
        var isEmpty: Bool { index.isEmpty }

        func append(_ entry: Entry) {
            index[entry.id] = slots.count
            slots.append(entry)
        }

        func entry(_ id: UInt64) -> Entry? {
            guard let slot = index[id] else { return nil }
            return slots[slot]
        }

        /// Sets the live entry's missed flag; returns false when `id` left.
        @discardableResult
        func setMissed(_ id: UInt64, _ missed: Bool) -> Bool {
            guard let slot = index[id] else { return false }
            slots[slot]?.missed = missed
            return true
        }

        func remove(_ id: UInt64) -> Entry? {
            guard let slot = index.removeValue(forKey: id) else { return nil }
            let entry = slots[slot]
            slots[slot] = nil
            if slots.count >= 16, slots.count > 2 * index.count { compact() }
            return entry
        }

        private func compact() {
            slots = slots.filter { $0 != nil }
            for (slot, entry) in slots.enumerated() {
                if let entry { index[entry.id] = slot }
            }
        }
    }

    /// The subscribers of one node waiting for their missed calls, in the order they were marked.
    private struct Pending {
        weak var node: VisibilityNode?
        var subscribers: [(name: Notification.Name, id: UInt64)] = []
        /// Marked subscribers still live; `subscribers` may also hold ones that left.
        var live = 0
        /// The node holds this fan-out's deferred call.
        var scheduled = false
    }

    /// The deferred-work key of this fan-out's one missed call on a node.
    private struct MissedKey: Hashable {
        let fanOut: ObjectIdentifier
    }

    private weak var center: NotificationCenter?
    /// The one sender observed; nil with ``scoped`` false observes every sender.
    private weak var object: AnyObject?
    private let scoped: Bool
    private var channels: [Notification.Name: Channel] = [:]
    private var pending: [ObjectIdentifier: Pending] = [:]
    /// The record count at which a new record first drops those of released nodes, doubled after
    /// each pass, so dropping costs O(1) amortized per record.
    private var pendingCompactAt = 16
    private var nextID: UInt64 = 0
    private var deliveryCounts: [Notification.Name: Int] = [:]
    private var deferrals = 0
    #if DEBUG || CMUX_BENCH_HOOKS
    /// Whose arm census records each observer this fan-out makes; nil records none.
    private let observerLedger: WakeupLedger?
    #endif

    /// - Parameters:
    ///   - object: The only sender observed, held weakly; nil observes every sender.
    ///   - center: Where the notifications are posted.
    ///   - observerLedger: In Debug and bench builds, the ledger whose arm census records each observer (one per
    ///     name, under its first subscriber's owner and line) and its first post; nil records none.
    init(object: AnyObject?, center: NotificationCenter, observerLedger: WakeupLedger? = nil) {
        self.object = object
        self.scoped = object != nil
        self.center = center
        #if DEBUG || CMUX_BENCH_HOOKS
        self.observerLedger = observerLedger
        #endif
    }

    private var missedKey: MissedKey { MissedKey(fanOut: ObjectIdentifier(self)) }

    func subscribe(_ name: Notification.Name, node: VisibilityNode?, delivery: EventDelivery, owner: String,
                   file: StaticString = #fileID, line: UInt = #line,
                   _ handler: @escaping @MainActor (EventCall) -> Void) -> EventSubscription {
        // A closed window posts nothing more; observing nil would hear every window.
        guard let center, !scoped || object != nil else { return EventSubscription(owner: owner, fanOut: nil, name: name, id: 0) }
        nextID &+= 1
        let id = nextID
        let channel = channels[name] ?? open(name, on: center, owner: owner, file: file, line: line)
        channel.append(Entry(id: id, delivery: delivery, node: node, handler: handler))
        return EventSubscription(owner: owner, fanOut: self, name: name, id: id)
    }

    func remove(_ name: Notification.Name, id: UInt64) {
        guard let channel = channels[name], let entry = channel.remove(id) else { return }
        if entry.missed, let node = entry.node { unmark(node) }
        // The last subscriber left: release the observation, which removes the observer.
        if channel.isEmpty { channels[name] = nil }
    }

    /// Whether a NotificationCenter observer for `name` exists.
    func isObserving(_ name: Notification.Name) -> Bool { channels[name] != nil }

    /// How many subscriptions to `name` are live.
    func subscriberCount(_ name: Notification.Name) -> Int { channels[name]?.count ?? 0 }

    /// How many times the center delivered `name` to this fan-out: one per post, however many
    /// subscribers, while it observes.
    func deliveries(_ name: Notification.Name) -> Int { deliveryCounts[name] ?? 0 }

    /// How many times this fan-out handed a node deferred work: one per node that went from no
    /// missed subscriber to one, however many posts and subscribers.
    var deferredWork: Int { deferrals }

    private func open(_ name: Notification.Name, on center: NotificationCenter, owner: String, file: StaticString,
                      line: UInt) -> Channel {
        let observation = MainActorObservation(name, object: object, center: center) { [weak self] in
            self?.deliver(name)
        }
        let channel = Channel(observation: observation)
        #if DEBUG || CMUX_BENCH_HOOKS
        if let observerLedger {
            channel.census.armed(in: observerLedger.armCensus, .observer, owner: "\(name.rawValue) (\(owner))",
                                 site: ArmCensus.Site(file: file, line: line))
        }
        #endif
        channels[name] = channel
        return channel
    }

    private func deliver(_ name: Notification.Name) { // perf-hot: 0.1ms cmd-tab (one call per post, O(subscribers to the name), no allocation for a missed one)
        deliveryCounts[name, default: 0] += 1
        guard let channel = channels[name] else { return }
        #if DEBUG || CMUX_BENCH_HOOKS
        if let observerLedger { channel.census.fired(in: observerLedger.armCensus) }
        #endif
        // A handler may subscribe or cancel: walk the slots as they were and skip the ones that left.
        // A subscriber added during the walk is not called for this post.
        for case let entry? in channel.slots {
            guard let live = channel.entry(entry.id) else { continue }
            if live.delivery == .always {
                live.handler(.posted)
            } else if let node = live.node {
                if node.wantsFrames {
                    live.handler(.posted)
                } else if !live.missed {
                    channel.setMissed(live.id, true)
                    mark(name, id: live.id, on: node)
                }
            }
        }
    }

    /// Adds a newly missed subscriber to its node's pending list; the first one hands the node
    /// this fan-out's one deferred call.
    private func mark(_ name: Notification.Name, id: UInt64, on node: VisibilityNode) {
        let key = ObjectIdentifier(node)
        // A record whose node was released belongs to an old node at the same address.
        var record = pending[key].flatMap { $0.node === node ? $0 : nil } ?? newRecord(for: node)
        record.subscribers.append((name: name, id: id))
        record.live += 1
        pending[key] = record
        schedule(on: node)
    }

    private func newRecord(for node: VisibilityNode) -> Pending {
        if pending.count >= pendingCompactAt {
            pending = pending.filter { $0.value.node != nil }
            pendingCompactAt = max(16, 2 * pending.count)
        }
        return Pending(node: node)
    }

    private func unmark(_ node: VisibilityNode) {
        let key = ObjectIdentifier(node)
        guard var record = pending[key], record.node === node else { return }
        record.live -= 1
        guard record.live > 0 else {
            pending[key] = nil
            node.cancelDeferred(key: missedKey)
            return
        }
        // Cancelled subscribers stay in the list until a show; drop them once they are most of it.
        if record.subscribers.count >= 16, record.subscribers.count > 2 * record.live {
            record.subscribers.removeAll { channels[$0.name]?.entry($0.id)?.missed != true }
        }
        pending[key] = record
    }

    private func schedule(on node: VisibilityNode) {
        let key = ObjectIdentifier(node)
        guard let record = pending[key], !record.scheduled, record.live > 0 else { return }
        pending[key]?.scheduled = true
        deferrals += 1
        node.deferUntilVisible(key: missedKey) { [weak self, weak node] in
            guard let self, let node else { return }
            self.deliverMissed(on: node)
        }
    }

    /// The node renders again: calls its missed subscribers in the order they were marked. A
    /// handler that stops it rendering leaves the rest marked for the next time it renders.
    private func deliverMissed(on node: VisibilityNode) {
        let key = ObjectIdentifier(node)
        guard var record = pending[key], record.node === node else { return }
        let batch = record.subscribers
        record.subscribers = []
        record.scheduled = false
        pending[key] = record
        var next = 0
        while next < batch.count, node.wantsFrames {
            let subscriber = batch[next]
            next += 1
            guard let channel = channels[subscriber.name], let entry = channel.entry(subscriber.id), entry.missed else { continue }
            channel.setMissed(subscriber.id, false)
            pending[key]?.live -= 1
            entry.handler(.missed)
        }
        guard var rest = pending[key], rest.node === node else { return }
        guard rest.live > 0 else {
            pending[key] = nil
            return
        }
        rest.subscribers.insert(contentsOf: batch[next...], at: 0)
        pending[key] = rest
        schedule(on: node)
    }
}
