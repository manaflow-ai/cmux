import AppKit
import CmuxNextCloud
import CoreGraphics
import CmuxNextDaemon
import Dispatch
import CmuxNextCompat
import Foundation
import IOKit.ps

/// What this computer says about itself that the daemon's host budget verdict does not, for Auto: a sleep the app is
/// told of, free disk and the person's idle time, and the callbacks that say something changed. Memory pressure and
/// battery are read once, by the daemon (`host_pressure`, with its `power`): here a memory or power event only wakes
/// Auto to ask again (RFD 0072). Whether any of it moves a chat is Rust's rule (`cloud_move_place_auto`, asked through
/// ``decide(_:session:nowMs:own:verdict:)``).
@MainActor
public final class CloudAutoSignals {
    /// What the system callbacks report, delivered in order to the one loop that owns them.
    public enum Event: Sendable { case asleep(Bool), memory, power, turnEnded(String) }

    /// What only the app reads (the rule's `verdict::Own`).
    public struct Own: Encodable, Sendable {
        public var sleeping: Bool
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

    /// Rust's answer: `stay`, `toCloud` (with the reason) or `back`, and the `auto-shadow.jsonl` line when the verdict
    /// alone would move the chat.
    public struct Answer: Decodable, Sendable {
        public var action: String, reason: String?, shadowLine: String?
        enum CodingKeys: String, CodingKey { case action = "do", reason, shadowLine }
    }

    public private(set) var sleeping = false
    nonisolated private let events: AsyncStream<Event>.Continuation
    private let stream: AsyncStream<Event>
    private var loop: Task<Void, Never>?
    private var pressure: DispatchSourceMemoryPressure?
    private var power: CFRunLoopSource?
    private var started = false
    /// The home volume's free bytes as last read (off the main thread); the next read is under way.
    private var diskFree: UInt64?
    private var diskRead = false
    private let handler: @MainActor (Event) -> Void

    /// `handler` runs on the main actor for each event, after `sleeping` holds the new value.
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
                case .memory, .power, .turnEnded: break
                }
                handler(event)
            }
        }
        let events = events
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: .main)
        // A wake only: the level itself is the daemon's verdict's.
        source.setEventHandler { events.yield(.memory) }
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

    /// Asks Rust what Auto does with one chat now, on the daemon's `host_pressure` verdict (raw JSON; nil when no
    /// daemon answered, which moves nothing for memory or battery).
    public func decide(_ chat: Chat, session: String, nowMs: UInt64, own: Own, verdict: Data?) -> Answer? {
        struct Request: Encodable { var mode: String, chat: Chat, session: String, nowMs: UInt64, own: Own, verdict: RawJSON? }
        let request = Request(mode: "auto", chat: chat, session: session, nowMs: nowMs, own: own, verdict: verdict.map(RawJSON.init))
        return CloudMoveCore().call("place_auto", request, as: Answer.self)
    }

    /// A JSON value passed through as it came.
    struct RawJSON: Encodable {
        let data: Data
        func encode(to encoder: any Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode((try? JSONDecoder().decode(JSONValue.self, from: data)) ?? .null)
        }
    }

    private func refreshDisk() {
        guard !diskRead else { return }
        diskRead = true
        // task-owner: one read of the home volume; it records the answer and ends.
        Task {
            let free = await Task.detached(priority: .utility) { try? FileManager.default.homeDirectoryForCurrentUser.blockingResourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage }.value
            diskFree = free.map { UInt64(max(0, $0)) }
            diskRead = false
        }
    }

    /// What the app reads of this computer now.
    public func own() -> Own {
        refreshDisk()
        // kCGAnyInputEventType: every kind of input.
        let idle = CGEventType(rawValue: ~0).map { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0) } ?? .nan
        return Own(sleeping: sleeping, diskFreeBytes: diskFree, idleMs: idle.isFinite && idle >= 0 ? UInt64(idle * 1000) : nil)
    }
}
