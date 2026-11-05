// SPDX-License-Identifier: GPL-3.0-or-later
// Ported from Petal's ai_chat/takeover.rs (kiruna-labs/petal @ 7ac436a,
// Apache-2.0, Copyright Kiruna Labs): a listen-only session tap, health
// proven by a marked round trip, re-enabled when the system disables it.
import ApplicationServices
import Darwin
import Foundation
import os

private let takeoverLogger = Logger(subsystem: "com.cmuxterm.cua", category: "takeover")

/// A listen-only `CGEventTap` on its own thread that tells the gate about
/// every input event and who made it. It never alters or swallows events.
///
/// Healthy means both: the tap is enabled, and a `mouseMoved` we posted to
/// the cursor's own position (invisible, disturbs nothing) came back with
/// our marker. Without the second, our own input could read as the
/// person's. Starting never asks for a permission: with no Accessibility
/// grant (`AXIsProcessTrusted`, no prompt) the tap is not created and the
/// gate stays unwatched.
public final class TakeoverTap: @unchecked Sendable {
    private struct State {
        var running = false
        var stop = false
        var markedSeen: UInt64 = 0
        /// Latencies (ns) from an event's own post time to the callback,
        /// for events whose user data carries a bench stamp.
        var stampedLatencies: [UInt64] = []
    }

    public let gate: TakeoverGate
    private let ownPID = Int64(getpid())
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let trusted: @Sendable () -> Bool

    /// The tap and its gate. The gate restarts the tap on each acting call,
    /// so a grant given after launch brings it up without a relaunch.
    public init(rule: TakeoverRule = TakeoverRule(),
                trusted: @escaping @Sendable () -> Bool = { AXIsProcessTrusted() }) {
        let ref = TapRef()
        gate = TakeoverGate(rule: rule, starter: { ref.tap?.ensureStarted() })
        self.trusted = trusted
        ref.tap = self
    }

    private final class TapRef: @unchecked Sendable {
        // Set once in init, before the gate can call it.
        weak var tap: TakeoverTap?
    }

    /// Start the tap thread if it is not running. Idempotent and cheap, so
    /// the gate calls it on every acting call.
    public func ensureStarted() {
        guard trusted() else { return }
        let start = state.withLock { state -> Bool in
            state.stop = false
            if state.running { return false }
            state.running = true
            return true
        }
        guard start else { return }
        let thread = Thread { [self] in
            run()
            gate.setHealthy(false)
            state.withLock { $0.running = false }
        }
        thread.name = "cmux-cua-takeover-tap"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    /// Ask the tap to stop; health drops at once.
    public func stop() {
        state.withLock { $0.stop = true }
        gate.setHealthy(false)
    }

    /// Bench stamps seen so far, then cleared.
    public func takeStampedLatencies() -> [UInt64] {
        state.withLock { state in
            defer { state.stampedLatencies.removeAll() }
            return state.stampedLatencies
        }
    }

    // MARK: Bench stamps

    /// A person-side bench process marks its events with this tag in the
    /// top 16 bits of the user data and its post time (uptime ns, low 48
    /// bits) below, so the tap can time post -> callback on one clock.
    /// The tag is not our marker, so the event still counts as the person's.
    static let benchTag: Int64 = 0x7E57
    public static func benchStamp(nanos: UInt64) -> Int64 {
        (benchTag << 48) | Int64(nanos & 0xFFFF_FFFF_FFFF)
    }

    static func benchLatency(userData: Int64, nowNanos: UInt64) -> UInt64? {
        guard userData >> 48 == benchTag else { return nil }
        let sent = UInt64(userData & 0xFFFF_FFFF_FFFF)
        let now = nowNanos & 0xFFFF_FFFF_FFFF
        return now >= sent ? now - sent : nil
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
        } else if let latency = Self.benchLatency(userData: userData, nowNanos: now) {
            state.withLock { if $0.stampedLatencies.count < 100_000 { $0.stampedLatencies.append(latency) } }
        }
        let location = event.location
        gate.observe(provenance, x: location.x, y: location.y, at: now)
    }

    private func run() {
        let box = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
            eventsOfInterest: CGEventMask(TapEventType.mask),
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
        gate.setHealthy(provenanceRoundTrips())
        while !state.withLock({ $0.stop }) {
            // A run loop wake, not a poll of the gate: events arrive as sources.
            CFRunLoopRunInMode(.defaultMode, 0.25, false)
            if !CGEvent.tapIsEnabled(tap: tap) {
                gate.setHealthy(false)
                CGEvent.tapEnable(tap: tap, enable: true)
                if CGEvent.tapIsEnabled(tap: tap) { gate.setHealthy(provenanceRoundTrips()) }
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
