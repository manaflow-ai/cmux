import AppKit
import CmuxNextCloud
import CoreGraphics
import Dispatch
import Foundation
import IOKit.ps

/// What this computer says about itself, for Auto (the reducer's `Signals`): sleep, battery, memory pressure, free
/// disk and the person's idle time, and the callbacks that say one changed. It reads and reports; whether any of it
/// moves a chat is Rust's rule (`cloud_move_place_auto`, asked through ``decide(_:signals:)``).
@MainActor
public final class CloudAutoSignals {
    /// What the system callbacks report, delivered in order to the one loop that owns them.
    public enum Event: Sendable { case asleep(Bool), memory(String), power, turnEnded(String) }

    public struct Signals: Encodable, Sendable {
        public var sleeping: Bool
        public var onBattery: Bool
        public var batteryPercent: Int?
        public var memory: String
        public var diskFreeBytes: UInt64?
        public var idleMs: UInt64?
    }

    /// One Auto chat as the rule reads it.
    public struct Chat: Encodable, Sendable {
        public var at: String, movedByAuto: Bool, turnRunning: Bool, turnMs: UInt64, queued: Int, idleMs: UInt64, moving: Bool
        public init(at: String, movedByAuto: Bool, turnRunning: Bool, turnMs: UInt64, queued: Int, idleMs: UInt64, moving: Bool) {
            self.at = at; self.movedByAuto = movedByAuto; self.turnRunning = turnRunning; self.turnMs = turnMs
            self.queued = queued; self.idleMs = idleMs; self.moving = moving
        }
    }

    /// Rust's answer: `stay`, `toCloud` (with the reason) or `back`.
    public struct Answer: Decodable, Sendable {
        public var action: String, reason: String?
        enum CodingKeys: String, CodingKey { case action = "do", reason }
    }

    public private(set) var sleeping = false
    public private(set) var memory = "normal"
    nonisolated private let events: AsyncStream<Event>.Continuation
    private let stream: AsyncStream<Event>
    private var loop: Task<Void, Never>?
    private var pressure: DispatchSourceMemoryPressure?
    private var power: CFRunLoopSource?
    private var started = false
    private let handler: @MainActor (Event) -> Void

    /// `handler` runs on the main actor for each event, after `sleeping` and `memory` hold the new value.
    public init(handler: @escaping @MainActor (Event) -> Void) {
        self.handler = handler
        (stream, events) = AsyncStream<Event>.makeStream(bufferingPolicy: .bufferingNewest(64))
    }

    /// Finishing the stream ends the loop.
    nonisolated deinit { events.finish() }

    /// A change the app's own adapters know of (sleep, wake, a turn that ended) joins the same ordered loop.
    public nonisolated func post(_ event: Event) { events.yield(event) }

    /// Starts the memory pressure and power watches and the loop that delivers every event.
    public func start() {
        guard !started else { return }
        started = true
        let stream = stream
        loop = Task { [weak self] in
            for await event in stream {
                guard let self else { return }
                switch event {
                case .asleep(let asleep): sleeping = asleep
                case .memory(let level): memory = level
                case .power, .turnEnded: break
                }
                handler(event)
            }
        }
        let events = events
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: .main)
        source.setEventHandler { [weak source] in
            guard let event = source?.data else { return }
            events.yield(.memory(event.contains(.critical) ? "critical" : event.contains(.warning) ? "warn" : "normal"))
        }
        source.resume()
        pressure = source
        let context = Unmanaged.passUnretained(self).toOpaque()
        if let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            Unmanaged<CloudAutoSignals>.fromOpaque(context).takeUnretainedValue().events.yield(.power)
        }, context)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
            power = source
        }
    }

    /// Asks Rust what Auto does with one chat now.
    public func decide(_ chat: Chat, signals: Signals) -> Answer? {
        struct Request: Encodable { var mode: String, chat: Chat, signals: Signals }
        return CloudMoveCore().call("place_auto", Request(mode: "auto", chat: chat, signals: signals), as: Answer.self)
    }

    /// This computer now.
    public func signals() -> Signals {
        var onBattery = false, percent: Int?
        if let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(), let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] {
            for source in list {
                guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                      description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else { continue }
                onBattery = description[kIOPSPowerSourceStateKey] as? String == kIOPSBatteryPowerValue
                if let current = description[kIOPSCurrentCapacityKey] as? Int, let maximum = description[kIOPSMaxCapacityKey] as? Int, maximum > 0 {
                    percent = min(100, current * 100 / maximum)
                }
            }
        }
        let free = try? FileManager.default.homeDirectoryForCurrentUser.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage
        // kCGAnyInputEventType: every kind of input.
        let idle = CGEventType(rawValue: ~0).map { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0) } ?? .nan
        return Signals(sleeping: sleeping, onBattery: onBattery, batteryPercent: percent, memory: memory, diskFreeBytes: free.map { UInt64(max(0, $0)) },
                       idleMs: idle.isFinite && idle >= 0 ? UInt64(idle * 1000) : nil)
    }
}
