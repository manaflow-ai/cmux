import AppKit
import CmuxNextBridge
import CmuxNextCloud
import CmuxNextWakeups
import CoreGraphics
import Dispatch
import Foundation
import IOKit.ps

/// What this computer says about itself, for Auto (the reducer's `Signals`): sleep, battery, memory pressure, free
/// disk and the person's idle time. It reads and reports; whether any of it moves a chat is Rust's rule
/// (`cloud_move_place_auto`).
@MainActor
final class CloudAutoMonitor {
    private let services: AppServices
    private var started = false
    private var sleeping = false
    private var memory = "normal"
    private var observers: [any NSObjectProtocol] = []
    private var pressure: DispatchSourceMemoryPressure?
    private var power: CFRunLoopSource?
    /// The next re-read while an Auto chat exists; none is scheduled when no chat is on Auto.
    private let tick = DemandTimer(owner: "CloudAutoMonitor.tick")
    /// When each session's last turn ended (for the rule's idle time).
    private var turnEnded: [String: UInt64] = [:]

    /// How often Auto reads again with no change to wake it.
    static let interval: TimeInterval = 30

    init(services: AppServices) { self.services = services }

    /// Starts watching: every change of a signal asks Rust about each Auto chat, and while one is on Auto a 30 second
    /// deadline asks again (idle time and long turns change with no event).
    func start() {
        guard !started else { return }
        started = true
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.sleeping = true; self?.evaluate() }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.sleeping = false; self?.evaluate() }
        })
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: .main)
        source.setEventHandler { [weak self, weak source] in
            guard let event = source?.data else { return }
            let level = event.contains(.critical) ? "critical" : event.contains(.warning) ? "warn" : "normal"
            Task { @MainActor in
                guard let self else { return }
                self.memory = level
                self.evaluate()
            }
        }
        source.resume()
        pressure = source
        let context = Unmanaged.passUnretained(self).toOpaque()
        if let loop = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let monitor = Unmanaged<CloudAutoMonitor>.fromOpaque(context).takeUnretainedValue()
            Task { @MainActor in monitor.evaluate() }
        }, context)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), loop, .defaultMode)
            power = loop
        }
        AgentTurnStateStore.shared.turnEndedObservers.append { [weak self] session, _ in
            Task { @MainActor in guard let self else { return }; self.turnEnded[session] = self.services.cloud.place.nowMs }
        }
    }

    /// Asks Rust what to do with each Auto chat now, and runs the moves it names.
    func evaluate() {
        let place = services.cloud.place
        let autos = CloudPlaceRun(services: services).chats().filter { place.mode(of: $0.session) == "auto" }
        guard !autos.isEmpty else { tick.cancel(); return }
        tick.schedule(after: .seconds(Self.interval)) { @MainActor [weak self] in self?.evaluate() }
        let signals = self.signals()
        let nowMs = place.nowMs
        for chat in autos {
            // A move that failed or was cancelled waits for the person (Retry), never an Auto loop.
            if let state = place.state(of: chat.session), state == "failed" || state == "cancelled" { continue }
            let running = CloudPlaceCargo.read(tab: chat.tab, session: chat.session, services: services).turnRunning
            let startedMs = chat.tab.agentSession.flatMap { AgentTurnStateStore.shared.detail(for: $0)?.turnStartedAtMs }
            let turnMs = running ? startedMs.map { UInt64(max(0, Date().timeIntervalSince1970 * 1000 - Double($0))) } ?? 0 : 0
            let ended = turnEnded[chat.session]
            let request = AutoRequest(mode: "auto", chat: .init(at: chat.onCloud ? "cloud" : "local", movedByAuto: place.autoMoved.contains(chat.session),
                                                                 turnRunning: running, turnMs: turnMs, queued: 0,
                                                                 idleMs: running ? 0 : ended.map { nowMs &- $0 } ?? signals.idleMs ?? 0,
                                                                 moving: place.isMoving(chat.session) || services.cloud.movingBack.contains(chat.tab.id)),
                                      signals: signals)
            guard let answer = CloudMoveCore().call("place_auto", request, as: AutoAnswer.self) else { continue }
            let run = CloudPlaceRun(services: services)
            switch answer.action {
            case "toCloud": run.move(chat, toCloud: true, trigger: .auto(answer.reason ?? "away"))
            case "back": run.move(chat, toCloud: false, trigger: .auto("back"))
            default: break
            }
        }
    }

    struct AutoRequest: Encodable {
        struct Chat: Encodable { var at: String, movedByAuto: Bool, turnRunning: Bool, turnMs: UInt64, queued: Int, idleMs: UInt64, moving: Bool }
        var mode: String
        var chat: Chat
        var signals: Signals
    }

    struct AutoAnswer: Decodable {
        var action: String, reason: String?
        enum CodingKeys: String, CodingKey { case action = "do", reason }
    }

    struct Signals: Encodable {
        var sleeping: Bool
        var onBattery: Bool
        var batteryPercent: Int?
        var memory: String
        var diskFreeBytes: UInt64?
        var idleMs: UInt64?
    }

    /// This computer now.
    func signals() -> Signals {
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
