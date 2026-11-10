// SPDX-License-Identifier: GPL-3.0-or-later
// Ported from Petal's ai_chat/takeover.rs (kiruna-labs/petal @ 7ac436a,
// Apache-2.0, Copyright Kiruna Labs): a listen-only session tap, health
// proven by a marked round trip, re-enabled when the system disables it.
import ApplicationServices
import Darwin
import Foundation
import os

private let takeoverLogger = Logger(subsystem: "com.cmuxterm.remote", category: "computer-use.takeover")

/// A listen-only `CGEventTap` on its own thread that tells the gate about
/// every input event and who made it. It never alters or swallows events.
///
/// Healthy means both: the tap is enabled, and a `mouseMoved` we posted to
/// the cursor's own position (invisible, disturbs nothing) came back with
/// our marker. Without the second, our own input could read as the
/// person's. Starting never asks for a permission: with no Accessibility
/// grant (`AXIsProcessTrusted`, no prompt) the tap is not created and the
/// gate stays unwatched, and without Input Monitoring
/// (`CGPreflightListenEventAccess`, no prompt) it listens to the pointer
/// and scrolls only, since a listen-only tap on keys is what asks for that
/// grant.
final class TakeoverTap: @unchecked Sendable { // crash-allow: every mutable field is behind `state`'s lock
    private struct State {
        var running = false
        var stop = false
        var markedSeen: UInt64 = 0
        /// An acting call asked for the detector since the last proof attempt.
        var proofWanted = false
    }

    let gate: TakeoverGate
    private let ownPID = Int64(getpid())
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let trusted: @Sendable () -> Bool
    private let listenKeys: @Sendable () -> Bool

    /// The tap and its gate. The gate restarts the tap on each acting call,
    /// so a grant given after launch brings it up without a relaunch.
    init(rule: TakeoverRule = TakeoverRule(),
         trusted: @escaping @Sendable () -> Bool = { AXIsProcessTrusted() },
         listenKeys: @escaping @Sendable () -> Bool = { CGPreflightListenEventAccess() }) {
        let ref = TapRef()
        gate = TakeoverGate(rule: rule, starter: { ref.tap?.ensureStarted() })
        self.trusted = trusted
        self.listenKeys = listenKeys
        ref.tap = self
    }

    private final class TapRef: @unchecked Sendable {
        // Set once in init, before the gate can call it.
        weak var tap: TakeoverTap?
    }

    /// Start the tap thread if it is not running. Idempotent and cheap, so
    /// the gate calls it on every acting call.
    func ensureStarted() {
        guard trusted() else { return }
        let start = state.withLock { state -> Bool in
            // A running but unproven tap retries its proof on the next run-loop turn.
            state.proofWanted = true
            // A thread still winding down after stop() ends first; the next call starts a new one.
            if state.running { return false }
            state.stop = false
            state.running = true
            return true
        }
        guard start else { return }
        let thread = Thread { [self] in
            run()
            gate.setHealthy(false)
            state.withLock { $0.running = false }
        }
        thread.name = "cmux-remote-cu-takeover-tap"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    /// Ask the tap to stop; health drops at once.
    func stop() {
        state.withLock { $0.stop = true }
        gate.setHealthy(false)
    }

    // MARK: The tap thread

    fileprivate func handle(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            // Until the loop re-enables it we cannot see the person.
            gate.setHealthy(false)
            return
        }
        let now = TakeoverGate.uptimeNanos()
        let userData = event.getIntegerValueField(.eventSourceUserData)
        let sourcePID = event.getIntegerValueField(.eventSourceUnixProcessID)
        let provenance = classifyInput(type: type.rawValue, userData: userData, sourcePID: sourcePID, ownPID: ownPID)
        if userData == TakeoverMarker.value {
            state.withLock { $0.markedSeen += 1 }
        }
        let location = event.location
        gate.observe(provenance, x: location.x, y: location.y, at: now)
    }

    private func run() {
        let box = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
            eventsOfInterest: CGEventMask(listenKeys() ? TapEventType.mask : TapEventType.pointerOnlyMask),
            callback: { _, type, event, info in
                if let info { Unmanaged<TakeoverTap>.fromOpaque(info).takeUnretainedValue().handle(type: type, event: event) }
                return Unmanaged.passUnretained(event)
            },
            userInfo: box
        ) else {
            takeoverLogger.warning("takeover tap unavailable (CGEventTapCreate refused); the gate stays unwatched")
            return
        }
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .defaultMode)
        CGEvent.tapEnable(tap: tap, enable: true)
        var healthy = provenanceRoundTrips()
        gate.setHealthy(healthy)
        var lastProof = TakeoverGate.uptimeNanos()
        while !state.withLock({ $0.stop }) {
            // A run loop wake, not a poll of the gate: events arrive as sources.
            CFRunLoopRunInMode(.defaultMode, 0.25, false)
            if !CGEvent.tapIsEnabled(tap: tap) {
                healthy = false
                gate.setHealthy(false)
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            // An unproven tap tries the round trip again, at most every 5 s and only when an
            // acting call asked since the last try: the marked move is posted at the HID tap,
            // where it shows a pointer macOS hid while the person types, so it never repeats on
            // its own while the agent is idle. A proven tap never re-posts.
            let now = TakeoverGate.uptimeNanos()
            if !healthy, CGEvent.tapIsEnabled(tap: tap), now &- lastProof >= 5_000_000_000,
               state.withLock({ state in
                   let wanted = state.proofWanted
                   state.proofWanted = false
                   return wanted
               }) {
                lastProof = now
                healthy = provenanceRoundTrips()
                gate.setHealthy(healthy)
            }
        }
        CGEvent.tapEnable(tap: tap, enable: false)
        CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .defaultMode)
        CFMachPortInvalidate(tap)
    }

    /// Post one marked `mouseMoved` to the cursor's position and pump this
    /// run loop until the tap sees it with the marker (up to 0.6 s).
    private func provenanceRoundTrips() -> Bool {
        let before = state.withLock { $0.markedSeen }
        guard Self.postMarkedMove() else { return false }
        for _ in 0..<12 {
            CFRunLoopRunInMode(.defaultMode, 0.05, true)
            if state.withLock({ $0.markedSeen }) > before {
                takeoverLogger.info("takeover tap live (provenance round trip confirmed)")
                return true
            }
        }
        takeoverLogger.warning("takeover tap could not prove provenance; the gate stays unwatched")
        return false
    }

    /// The one place cmux builds a marked event.
    @discardableResult
    static func postMarkedMove() -> Bool {
        let here = CGEvent(source: nil)?.location ?? .zero
        guard let source = CGEventSource(stateID: .hidSystemState) else { return false }
        source.userData = TakeoverMarker.value
        guard let event = CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: here,
                                  mouseButton: .left) else { return false }
        event.post(tap: .cghidEventTap)
        return true
    }
}
