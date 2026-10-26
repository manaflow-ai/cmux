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

    /// The mode when `environment` asks for it and Chromium runs in this process, else nil: in host
    /// mode the events and the mirror reads already come from the host's wire.
    static func requested(by environment: [String: String], inHostMode: Bool = false) -> CEFDeferredEvents? {
        !inHostMode && environment[environmentKey] == "1" ? CEFDeferredEvents() : nil
    }

    /// The mirror reads, once the runtime's shim reads them (``serveMirror(from:helloNow:)``).
    private(set) var mirror: CEFMirrorCache?
    private var pending: [Pending] = []
    private var drainScheduled = false
    private let nextTurn: CEFLayerHosting.Scheduler
    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "cef")

    /// A received event, the mirror values its batch pushes, and where it goes.
    private struct Pending {
        let event: CEFShimEvent
        let updates: [CEFMirrorCache.Update]
        let deliver: (CEFShimEvent) -> Void
    }

    /// - Parameter nextTurn: runs a block on a later main turn; tests run it when they choose.
    init(nextTurn: @escaping CEFLayerHosting.Scheduler = { CEFLayerHosting.atEndOfTurn($0) }) {
        self.nextTurn = nextTurn
    }

    /// Events received and not delivered yet.
    var queued: Int { pending.count }

    /// `shim` with its mirror exports served from a cache over it (``CEFMirrorCache/shim(helloNow:)``).
    /// `shim` itself, with a fault, when the cache cannot be served: another runtime's is, or a
    /// resolver lost an export it gave before. Its events are still deferred.
    func serveMirror(from shim: CEFShimLibrary, helloNow: Bool) -> CEFShimLibrary {
        let mirror = CEFMirrorCache(source: shim)
        do {
            let served = try mirror.shim(helloNow: helloNow)
            self.mirror = mirror
            return served
        } catch {
            logger.fault("deferred CEF events: mirror reads stay live (\(String(describing: error), privacy: .public))")
            return shim
        }
    }

    /// The shim's `event_fn`: the event's mirror values are read now, while Chromium's state is the
    /// event's, and both wait for a later turn, where `deliver` runs the event after every event
    /// received before it.
    func receive(_ event: CEFShimEvent, deliver: @escaping (CEFShimEvent) -> Void) {
        pending.append(Pending(event: event, updates: mirror?.updates(for: event) ?? [], deliver: deliver))
        guard !drainScheduled else { return }
        drainScheduled = true
        nextTurn { [weak self] in self?.drain() }
    }

    /// Delivers what was queued before this turn, in order. Events that one's handling causes wait
    /// for the next turn, as a host batch never holds the answers to its own handling.
    private func drain() {
        drainScheduled = false
        let batch = pending
        pending = []
        for item in batch {
            mirror?.apply(item.updates)
            item.deliver(item.event)
        }
    }
}

extension CEFRuntime {
    /// The shim's `event_fn`: runs the event now, or on a later turn in deferred mode.
    func receive(_ event: CEFShimEvent) {
        guard let deferredEvents else { return dispatch(event) }
        deferredEvents.receive(event) { [weak self] in self?.dispatch($0) }
    }

    /// Tests standing in for the shim take the shim's path: in deferred mode the event waits for a
    /// later turn like every other.
    func handle(_ event: CEFShimEvent) {
        receive(event)
    }
}
