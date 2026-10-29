public import AppKit
import os

/// One window's held keys: every key-down a cmux path holds because the target it was typed for cannot take keys yet
/// (a new terminal whose view is not the first responder, a New Tab page whose field is not ready, a new workspace's
/// terminal the window does not show yet). It replaces the per-path holds (`CreationInputCoordinator`'s buffers,
/// `NewTabInputCoordinator`, `GivenBackInput`) with one owned queue and one rule set (principled audit, lagFirstKey):
///
/// - Each key is stamped with the target it was typed for (``capture(_:for:)``) and is delivered exactly once, in typed
///   order, only to that target, and only while that target's view takes keys (``drain(_:takesKeys:deliver:)``).
/// - Release is level-triggered: the owner calls ``drain(_:takesKeys:deliver:)`` on each key and on each focus-model
///   change with the target the model names and whether its view is the first responder. Nothing replays an edge.
/// - A target that closes or fails, or that the person moves the focus away from, drops its keys with a reason
///   (``drop(_:_:)``), logged; they never go to another target. No timer decides where or whether a key goes.
/// - The owner frees the queue with its window (``close()``): every key still waiting drops as ``DropReason/windowClosed``.
///
/// Invariant (checked by ``problems``, after every change in DEBUG builds): captured == delivered + dropped + waiting,
/// and each target's keys are delivered in the order they were typed.
@MainActor
public final class WindowInputQueue {
    /// What a key was typed for: a tab id (a terminal or a page), or a workspace not shown yet.
    public struct Target: Hashable, Sendable, CustomStringConvertible {
        public let id: String
        public init(_ id: String) { self.id = id }
        public var description: String { id }
    }

    /// Why a target's keys dropped.
    public enum DropReason: String, Sendable {
        /// The person closed the target before it took keys.
        case targetClosed
        /// The target's creation failed (the daemon refused it, or its view never attached).
        case targetFailed
        /// The person moved the window's focus to another target: keys typed for the old one are not run later.
        case focusMovedAway
        /// The window closed.
        case windowClosed
    }

    /// Keys since the queue was made.
    public struct Counts: Equatable, Sendable {
        public var captured: Int
        public var delivered: Int
        public var dropped: Int

        public init(captured: Int = 0, delivered: Int = 0, dropped: Int = 0) {
            self.captured = captured
            self.delivered = delivered
            self.dropped = dropped
        }
    }

    private struct Held {
        let sequence: UInt64
        let event: NSEvent
        let target: Target
    }

    private var held: [Held] = []
    private var nextSequence: UInt64 = 0
    /// The last delivered key's sequence per target (the order half of the invariant).
    private var lastDelivered: [Target: UInt64] = [:]
    private var orderBroken: [Target] = []
    public private(set) var counts = Counts()
    /// Called once per drop with the target, the reason and how many keys dropped (the owner logs it).
    private let dropped: (Target, DropReason, Int) -> Void
    private static let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "input.queue")

    /// - Parameter dropped: Told each drop (the target, why, how many keys); the default logs it.
    public init(dropped: ((Target, DropReason, Int) -> Void)? = nil) {
        self.dropped = dropped ?? { target, reason, count in
            Self.logger.info("held keys dropped: target=\(target.id, privacy: .public) reason=\(reason.rawValue, privacy: .public) keys=\(count)")
        }
    }

    /// Whether no key waits.
    public var isEmpty: Bool { held.isEmpty }

    /// How many keys wait for `target`.
    public func waiting(for target: Target) -> Int { held.reduce(0) { $0 + ($1.target == target ? 1 : 0) } }

    /// The targets keys wait for, in the order of their first waiting key.
    public var targets: [Target] {
        var seen = Set<Target>()
        return held.compactMap { seen.insert($0.target).inserted ? $0.target : nil }
    }

    /// Holds `event`, typed for `target`, behind the keys already waiting.
    public func capture(_ event: NSEvent, for target: Target) {
        held.append(Held(sequence: nextSequence, event: event, target: target))
        nextSequence &+= 1
        counts.captured += 1
        debugCheck()
    }

    /// Delivers the keys typed for `target`, oldest first, while `takesKeys()` stays true (it is asked again before
    /// each key: a delivered key may move the keyboard). A key held again while it runs (``capture(_:for:)`` inside
    /// `deliver`) waits behind the rest. Returns how many keys went.
    @discardableResult
    public func drain(_ target: Target, takesKeys: () -> Bool, deliver: (NSEvent) -> Void) -> Int {
        var count = 0
        while let index = held.firstIndex(where: { $0.target == target }), takesKeys() {
            let key = held.remove(at: index)
            if let last = lastDelivered[target], key.sequence < last { orderBroken.append(target) }
            lastDelivered[target] = key.sequence
            counts.delivered += 1
            count += 1
            deliver(key.event)
        }
        debugCheck()
        return count
    }

    /// Drops every key waiting for `target` (`reason` says why). Returns how many dropped.
    @discardableResult
    public func drop(_ target: Target, _ reason: DropReason) -> Int {
        let before = held.count
        held.removeAll { $0.target == target }
        let count = before - held.count
        guard count > 0 else { return 0 }
        counts.dropped += count
        dropped(target, reason, count)
        debugCheck()
        return count
    }

    /// `old` is `new` from now on (a stand-in tab adopted by the daemon's tab: the same terminal, a new id).
    public func retarget(_ old: Target, to new: Target) {
        guard old != new else { return }
        held = held.map { $0.target == old ? Held(sequence: $0.sequence, event: $0.event, target: new) : $0 }
        if let last = lastDelivered.removeValue(forKey: old) { lastDelivered[new] = max(last, lastDelivered[new] ?? 0) }
    }

    /// The window closed: every waiting key drops.
    public func close() {
        for target in targets { drop(target, .windowClosed) }
    }

    /// The invariant's broken parts, empty when it holds.
    public var problems: [String] {
        var out: [String] = []
        if counts.captured != counts.delivered + counts.dropped + held.count {
            out.append("captured \(counts.captured) != delivered \(counts.delivered) + dropped \(counts.dropped) + waiting \(held.count)")
        }
        for target in orderBroken { out.append("keys for \(target) delivered out of typed order") }
        return out
    }

    private func debugCheck() {
        #if DEBUG
        for problem in problems { Self.logger.fault("held key invariant: \(problem, privacy: .public)") }
        #endif
    }
}
