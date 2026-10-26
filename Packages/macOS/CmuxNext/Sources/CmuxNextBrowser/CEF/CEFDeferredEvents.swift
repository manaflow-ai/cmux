import Foundation
import os

/// `CMUX_CEF_DEFER_EVENTS=1`: the in-process backend runs Chromium's events the way host mode will
/// (task 231 of plans/cmux-next/chrome-parity/p01-process.md). Every `event_fn` call is queued and
/// delivered on a later main turn, after the shim call that caused it returned, with the mirror
/// values it refreshes (``CEFMirrorCache``), as the remote shim delivers each batch it reads from the
/// host's wire. Code that needs an event inside the call that caused it, or a mirror read fresher
/// than the last batch, fails in this mode: each such test is one Q16 item, fixed before 021-028.
///
/// As a mojo receiver runs each message as its own task on the receiver's sequence, never inside
/// the sender's call (mojo/public/cpp/bindings/receiver.h).
final class CEFDeferredEvents {
    nonisolated static let environmentKey = "CMUX_CEF_DEFER_EVENTS"

    /// The mode when `environment` asks for it, else nil.
    static func requested(by environment: [String: String]) -> CEFDeferredEvents? {
        environment[environmentKey] == "1" ? CEFDeferredEvents() : nil
    }

    /// The mirror reads, once the runtime's shim reads them (``serveMirror(from:)``).
    private(set) var mirror: CEFMirrorCache?
    private var pending: [(event: CEFShimEvent, updates: [CEFMirrorCache.Update])] = []
    private var drainScheduled = false
    private let nextTurn: CEFLayerHosting.Scheduler
    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "cef")

    /// - Parameter nextTurn: runs a block on a later main turn; tests run it when they choose.
    init(nextTurn: @escaping CEFLayerHosting.Scheduler = { CEFLayerHosting.atEndOfTurn($0) }) {
        self.nextTurn = nextTurn
    }

    /// Events received and not delivered yet.
    var queued: Int { pending.count }

    /// `shim` with its mirror exports served from a cache over it. `shim` itself, with a fault, when
    /// the overriding shim cannot be made (only a resolver that lost an export it gave before).
    func serveMirror(from shim: CEFShimLibrary) -> CEFShimLibrary {
        let mirror = CEFMirrorCache(source: shim)
        do {
            let served = try mirror.shim()
            self.mirror = mirror
            return served
        } catch {
            logger.fault("deferred CEF events: mirror reads stay live (\(String(describing: error), privacy: .public))")
            return shim
        }
    }

    /// The shim's `event_fn`: the event's mirror values are read now, while Chromium's state is the
    /// event's, and both wait for a later turn, where `runtime` dispatches them in order.
    func receive(_ event: CEFShimEvent, in runtime: CEFRuntime) {
        pending.append((event, mirror?.updates(for: event) ?? []))
        guard !drainScheduled else { return }
        drainScheduled = true
        nextTurn { [weak self, weak runtime] in
            guard let runtime else { return }
            self?.drain(into: runtime)
        }
    }

    /// An event `runtime` dispatches now, from outside the shim (a test standing in for the host's
    /// batch): its mirror values are pushed first, as the host pushes them before the event.
    func deliverNow(_ event: CEFShimEvent, in runtime: CEFRuntime) {
        if let mirror { mirror.apply(mirror.updates(for: event)) }
        runtime.dispatch(event)
    }

    /// Dispatches what was queued before this turn, in order. Events that one's handling causes wait
    /// for the next turn, as a host batch never holds the answers to its own handling.
    private func drain(into runtime: CEFRuntime) {
        drainScheduled = false
        let batch = pending
        pending = []
        for (event, updates) in batch {
            mirror?.apply(updates)
            runtime.dispatch(event)
        }
    }
}

extension CEFRuntime {
    /// The shim's `event_fn`: runs the event now, or on a later turn in deferred mode.
    func receive(_ event: CEFShimEvent) {
        if let deferredEvents { deferredEvents.receive(event, in: self) } else { dispatch(event) }
    }

    /// Runs an event now (tests standing in for the shim); in deferred mode its mirror values first.
    func handle(_ event: CEFShimEvent) {
        if let deferredEvents { deferredEvents.deliverNow(event, in: self) } else { dispatch(event) }
    }
}
