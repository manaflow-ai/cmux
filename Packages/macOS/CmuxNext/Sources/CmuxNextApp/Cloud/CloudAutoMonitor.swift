import CmuxNextBridge
import CmuxNextCloudPlace
import CmuxNextWakeups
import Foundation

/// Runs Auto: every change of a signal (``CloudAutoSignals``) and, while a chat is on Auto, a 30 second deadline asks Rust
/// about each Auto chat and runs the move it names.
@MainActor
final class CloudAutoMonitor {
    private let services: AppServices
    private var signals: CloudAutoSignals?
    /// The next re-read while an Auto chat exists; none is scheduled when no chat is on Auto.
    private let tick = DemandTimer(owner: "CloudAutoMonitor.tick")
    /// When each session's last turn ended (for the rule's idle time).
    private var turnEnded: [String: UInt64] = [:]

    /// How often Auto reads again with no change to wake it.
    static let interval: TimeInterval = 30

    init(services: AppServices) { self.services = services }

    /// Starts watching. Sleep and wake come in through ``slept(_:)``, from the app's one sleep/wake adapter.
    func start() {
        guard signals == nil else { return }
        let signals = CloudAutoSignals { [weak self] event in
            guard let self else { return }
            if case .turnEnded(let session) = event { turnEnded[session] = services.cloud.place.nowMs; return }
            evaluate()
        }
        self.signals = signals
        signals.start()
        AgentTurnStateStore.shared.turnEndedObservers.append { session, _ in signals.post(.turnEnded(session)) }
    }

    /// The system is about to sleep (true) or woke (false): told by the app's sleep/wake adapter.
    func slept(_ asleep: Bool) { signals?.post(.asleep(asleep)) }

    /// Asks Rust what to do with each Auto chat now, and runs the moves it names.
    func evaluate() {
        guard let signals else { return }
        let place = services.cloud.place
        let run = CloudPlaceRun(services: services)
        let autos = run.chats().filter { place.mode(of: $0.session) == "auto" }
        guard !autos.isEmpty else { tick.cancel(); return }
        tick.schedule(after: .seconds(Self.interval)) { @MainActor [weak self] in self?.evaluate() }
        let now = signals.signals()
        let nowMs = place.nowMs
        for chat in autos {
            // A move that failed or was cancelled waits for the person (Retry), never an Auto loop.
            if let state = place.state(of: chat.session), state == "failed" || state == "cancelled" { continue }
            let running = CloudPlaceCargo.read(tab: chat.tab, session: chat.session, services: services).turnRunning
            let startedMs = chat.tab.agentSession.flatMap { AgentTurnStateStore.shared.detail(for: $0)?.turnStartedAtMs }
            let turnMs = running ? startedMs.map { UInt64(max(0, Date().timeIntervalSince1970 * 1000 - Double($0))) } ?? 0 : 0
            let ended = turnEnded[chat.session]
            let ask = CloudAutoSignals.Chat(at: chat.onCloud ? "cloud" : "local", movedByAuto: place.autoMoved.contains(chat.session),
                                            turnRunning: running, turnMs: turnMs, queued: 0,
                                            idleMs: running ? 0 : ended.map { nowMs &- $0 } ?? now.idleMs ?? 0,
                                            moving: place.isMoving(chat.session) || services.cloud.movingBack.contains(chat.tab.id))
            guard let answer = signals.decide(ask, signals: now) else { continue }
            switch answer.action {
            case "toCloud": run.move(chat, toCloud: true, trigger: .auto(answer.reason ?? "away"))
            case "back": run.move(chat, toCloud: false, trigger: .auto("back"))
            default: break
            }
        }
    }
}
