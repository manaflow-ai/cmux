public import CmuxNextDaemon
import CmuxNextWakeups
public import Foundation

/// The person's own Mac as their personal inference gateway (cmux-tui `cli/inference_gateway_mac.rs`,
/// docs/inference-gateway.md): while the app is signed in it runs one bundled
/// `cmux inference gateway --personal --mac-logins --supervised`, which answers the person's Cloud
/// machines' model calls from the agent logins already on this Mac. Cloud machines hold only a
/// placeholder key; nothing is installed or signed in on them.
///
/// One child per app (the tag's own Cloud folder holds its marker and log); it restarts with backoff
/// when it exits, stops on sign-out, and ends with the app (it exits when its held stdin closes, so a
/// crash ends it too). The child turns the person's own gateway mode on once (`--enable-once`): a
/// person who turns it off later stays off. Another gateway of theirs taking over (`replaced`, another
/// Mac or tag) is not fought: this one starts again only when a Cloud chat starts here
/// (``ensureOnline(within:)``).
@MainActor
public final class PersonalGateway {
    public enum State: Equatable, Sendable {
        case stopped
        case starting
        case online
        /// Running, not connected: dialing again (`disconnected`), or the Cloud service refused it for now (`refused`).
        case offline(String)
        /// Another gateway of this person's took over; this one waits for a Cloud chat start here.
        case replaced
        /// No gateway could start (this build has no `cmux`); a Cloud chat start tries again.
        case unavailable
    }

    /// One running gateway child: its state lines, and how to end it.
    public struct Child: Sendable {
        public var events: AsyncStream<String>
        public var exited: @Sendable () async -> Int32
        public var stop: @Sendable () -> Void

        public init(events: AsyncStream<String>, exited: @escaping @Sendable () async -> Int32, stop: @escaping @Sendable () -> Void) {
            (self.events, self.exited, self.stop) = (events, exited, stop)
        }
    }

    public private(set) var state: State = .stopped
    /// What happened, newest last (bounded; for diagnostics).
    public private(set) var log: [String] = []

    private let launch: @MainActor () async -> Child?
    private let clock: any Clock<Duration>
    private var wanted = false
    private var child: Child?
    private var generation = 0
    private var restart: Task<Void, Never>?
    private var relaunch = Backoff(initial: .seconds(1), maximum: .seconds(30))
    /// A Cloud service that refuses the gateway (no grant yet, an older backend) is asked again rarely.
    private var refusedRelaunch = Backoff(initial: .seconds(60), maximum: .seconds(600))
    private var lastStop: String?
    private var waiters: [UUID: CheckedContinuation<Bool, Never>] = [:]
    private static let logLimit = 32

    /// - Parameter launch: Starts one gateway child; nil when this build has no `cmux` or it could not start.
    public init(launch: @escaping @MainActor () async -> Child?, clock: any Clock<Duration> = ContinuousClock()) {
        (self.launch, self.clock) = (launch, clock)
    }

    /// The live gateway: the bundled `cmux`, serving the person's own machines through `api`.
    /// - Parameters:
    ///   - folder: This app's Cloud folder (per tag): the enable-once marker and the gateway's log go there.
    public convenience init(cli: BundledExecutable, api: URL, folder: URL) {
        self.init(launch: { await Self.liveChild(cli: cli, api: api, folder: folder) })
    }

    /// Signed in: run the gateway (once; a running one stays).
    public func start() {
        wanted = true
        relaunch.reset()
        refusedRelaunch.reset()
        if child == nil, restart == nil { spawn() }
    }

    /// Signed out or quitting: end the child and every wait.
    public func stop() {
        wanted = false
        restart?.cancel()
        restart = nil
        generation += 1
        child?.stop()
        child = nil
        set(.stopped)
    }

    /// A Cloud chat starts on this Mac: the gateway runs and is connected before the first turn, or
    /// `deadline` passes (false). Never throws: a turn that still finds no gateway says so itself
    /// (`inference.gateway_offline`). A gateway another Mac took over, or one waiting out a refusal,
    /// starts again now.
    public func ensureOnline(within deadline: Duration) async -> Bool {
        guard wanted else { return false }
        if state == .online { return true }
        if state == .replaced || state == .unavailable || restart != nil {
            restart?.cancel()
            restart = nil
            relaunch.reset()
            if child == nil { spawn() }
        }
        // Refused at its last connect: asking again now is the restart above; waiting would only delay the turn.
        if lastStop == "refused", state != .starting { return false }
        let id = UUID()
        // task-owner: PersonalGateway.ensureOnline: the deadline of one wait; it ends when the wait does.
        let timer = Task { [weak self, clock] in
            // wakeup-allow: one-shot deadline for the gateway to come online before a Cloud chat's first turn.
            try? await clock.sleep(for: deadline)
            self?.finishWait(id, online: false)
        }
        defer { timer.cancel() }
        return await withCheckedContinuation { continuation in
            if state == .online { continuation.resume(returning: true); return }
            waiters[id] = continuation
        }
    }

    private func spawn() {
        generation += 1
        let mine = generation
        set(.starting)
        // task-owner: PersonalGateway.spawn: one child's life; stop() fences it by generation.
        Task { [weak self] in
            guard let self else { return }
            guard let child = await self.launch() else {
                guard mine == self.generation, self.wanted else { return }
                self.note("gateway could not start")
                self.set(.unavailable)
                return
            }
            guard mine == self.generation, self.wanted else { child.stop(); return }
            self.child = child
            for await line in child.events where mine == self.generation { self.handle(line) }
            let status = await child.exited()
            self.ended(mine, status: status)
        }
    }

    private func handle(_ line: String) {
        guard let object = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
              let event = object["event"] as? String else { return }
        let reason = object["reason"] as? String
        switch event {
        case "online":
            lastStop = nil
            relaunch.reset()
            refusedRelaunch.reset()
            set(.online)
        case "offline":
            set(.offline(reason ?? "disconnected"))
        case "stopped":
            lastStop = reason
        default:
            return
        }
    }

    private func ended(_ which: Int, status: Int32) {
        guard which == generation else { return }
        child = nil
        guard wanted else { set(.stopped); return }
        note("gateway exited (\(status), \(lastStop ?? "no reason"))")
        if lastStop == "replaced" { set(.replaced); return }
        let refused = lastStop == "refused"
        set(.offline(refused ? "refused" : "exited"))
        let delay = refused ? refusedRelaunch.next() : relaunch.next()
        // task-owner: PersonalGateway.ended: one relaunch per exit after a growing delay; stop() and ensureOnline cancel it.
        restart = Task { [weak self, clock] in
            // wakeup-allow: one-shot relaunch delay after the gateway exited.
            try? await clock.sleep(for: delay)
            guard let self, !Task.isCancelled, self.wanted else { return }
            self.restart = nil
            self.spawn()
        }
    }

    private func set(_ new: State) {
        state = new
        guard new == .online || new == .stopped || new == .replaced || new == .unavailable else { return }
        for id in Array(waiters.keys) { finishWait(id, online: new == .online) }
    }

    private func finishWait(_ id: UUID, online: Bool) {
        waiters.removeValue(forKey: id)?.resume(returning: online)
    }

    private func note(_ line: String) {
        log.append(line)
        if log.count > Self.logLimit { log.removeFirst(log.count - Self.logLimit) }
    }

    /// The argv of the live child (tests read it).
    nonisolated public static func arguments(api: URL, marker: URL) -> [String] {
        ["inference", "gateway", "--personal", "--mac-logins", "--supervised",
         "--enable-once", marker.path, "--api", api.absoluteString]
    }

    private static func liveChild(cli: BundledExecutable, api: URL, folder: URL) async -> Child? {
        guard let binary = await cli.resolve() else { return nil }
        // The gateway reads its token with the app's `cmux auth token` on every connect; a token a parent
        // environment carries is not this person's app session.
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "CMUX_CLOUD_ACCESS_TOKEN")
        let process = ChildProcess(executable: binary,
                                   arguments: arguments(api: api, marker: folder.appendingPathComponent("personal-gateway-on")),
                                   environment: environment, stderrLog: folder.appendingPathComponent("inference-gateway.log"))
        do { try process.startHoldingInput() } catch { return nil }
        return Child(events: process.lines, exited: { await process.waitForExit() }, stop: { process.closeInput() })
    }
}
