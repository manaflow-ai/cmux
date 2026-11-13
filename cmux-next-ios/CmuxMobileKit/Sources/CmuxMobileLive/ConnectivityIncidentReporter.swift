import CmuxConnectivityTelemetry
import Foundation
import OSLog
#if canImport(UIKit)
import UIKit
#endif

private let log = Logger(subsystem: "dev.cmux.mobile", category: "connectivity-incidents")

/// The build and phone a report came from (PROTOCOL.md "Connectivity incidents").
public struct ConnectivityIncidentApp: Sendable, Equatable, Codable {
    public var version: String
    public var build: String
    /// `AppStore`, `TestFlight`, `Production` or `Debug` (from the bundle id).
    public var config: String
    public var simulator: Bool
    public var model: String
    public var os: String

    public init(version: String, build: String, config: String, simulator: Bool, model: String, os: String) {
        self.version = version
        self.build = build
        self.config = config
        self.simulator = simulator
        self.model = model
        self.os = os
    }

    /// This process's build and phone.
    public static func current(bundle: Bundle = .main) -> ConnectivityIncidentApp {
        let info = bundle.infoDictionary ?? [:]
        let id = bundle.bundleIdentifier ?? ""
        let config = switch id {
        case "com.cmux.app": "AppStore"
        case "dev.cmux.app.internal": "TestFlight"
        case let id where id.hasSuffix(".prod"): "Production"
        default: "Debug"
        }
        #if targetEnvironment(simulator)
        let simulator = true
        let model = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] ?? "Simulator"
        #else
        let simulator = false
        var system = utsname()
        uname(&system)
        let model = withUnsafeBytes(of: &system.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        #endif
        let os = ProcessInfo.processInfo.operatingSystemVersion
        return ConnectivityIncidentApp(
            version: info["CFBundleShortVersionString"] as? String ?? "0",
            build: info["CFBundleVersion"] as? String ?? "0",
            config: config, simulator: simulator, model: model,
            os: "\(os.majorVersion).\(os.minorVersion)\(os.patchVersion > 0 ? ".\(os.patchVersion)" : "")")
    }
}

/// Reports waiting to be sent, kept on disk so an app kill or a service outage never loses one; sent in
/// order, each retried with backoff until the service accepts or refuses it for good.
public struct ConnectivityIncidentOutbox: Sendable, Equatable, Codable {
    public struct Entry: Sendable, Equatable, Codable {
        public var incident: ConnectivityIncidentDetector.Incident
        public var simulations: [String]
        public var tries = 0
        public var notBefore: Date?
        public var queuedAt: Date
    }

    /// What one send came to.
    public enum Result: Sendable, Equatable {
        case sent
        /// The service will never take it (refused, malformed): drop it.
        case refused
        /// Try again later (no network, the service down or rate limiting).
        case failed
    }

    /// Delays before each retry, in seconds; the last repeats.
    public static let backoff: [TimeInterval] = [5, 30, 120, 600, 1800]
    /// A report older than this is dropped unsent.
    public static let maxAge: TimeInterval = 7 * 86_400

    public private(set) var entries: [Entry] = []
    /// The incidents reported and not yet ended, with when the app last saw them (relaunch recovery).
    public var open: [String: OpenRecord] = [:]

    public struct OpenRecord: Sendable, Equatable, Codable {
        public var incident: ConnectivityIncidentDetector.Incident
        public var lastSeen: Date
    }

    public init() {}

    public mutating func enqueue(_ incident: ConnectivityIncidentDetector.Incident, simulations: [String], at date: Date) {
        entries.append(Entry(incident: incident, simulations: simulations, queuedAt: date))
        if incident.state == .open {
            open[incident.id] = OpenRecord(incident: incident, lastSeen: date)
        } else {
            open[incident.id] = nil
        }
    }

    /// The next entry to send at `date`, if one is due (the head only: order is kept).
    public mutating func next(at date: Date) -> Entry? {
        entries.removeAll { date.timeIntervalSince($0.queuedAt) > Self.maxAge }
        guard let head = entries.first else { return nil }
        if let notBefore = head.notBefore, notBefore > date { return nil }
        return head
    }

    /// When the head may be tried again, if it waits.
    public var retryAt: Date? { entries.first?.notBefore }

    /// Records the head's send.
    public mutating func finish(_ result: Result, at date: Date) {
        guard !entries.isEmpty else { return }
        switch result {
        case .sent, .refused:
            entries.removeFirst()
        case .failed:
            entries[0].tries += 1
            let wait = Self.backoff[min(entries[0].tries - 1, Self.backoff.count - 1)]
            entries[0].notBefore = date.addingTimeInterval(wait)
        }
    }

    /// The incidents a previous launch left open: each ends now as `app_relaunched`, at the time it was
    /// last seen (the app was killed or crashed while it was still unreachable).
    public mutating func recoverRelaunch(at date: Date) {
        // A new launch tries at once: the backoff was the last launch's.
        if !entries.isEmpty { entries[0].notBefore = nil }
        let left = open.values.sorted { $0.incident.startedAt < $1.incident.startedAt }
        open = [:]
        for record in left {
            var ended = record.incident
            ended.state = .ended
            ended.endReason = .appRelaunched
            ended.observedAt = max(record.lastSeen, record.incident.observedAt)
            entries.append(Entry(incident: ended, simulations: [], queuedAt: date))
        }
    }
}

/// Runs ``ConnectivityIncidentDetector`` for the signed-in account and sends what it reports to the
/// service, which posts it to the cmux team's Slack (only for a verified team account; the service
/// decides). Nothing runs for anyone outside the team: their phones never check or send.
@MainActor
public final class ConnectivityIncidentReporter {
    /// Sends one report; throws ``LiveAPI/Failure`` or a transport error.
    public typealias Send = @Sendable (ConnectivityIncidentDetector.Incident, [String], ConnectivityIncidentApp) async throws -> Void
    /// Whether the phone reaches the internet at large and the cmux service.
    public typealias Check = @Sendable () async -> (internet: Bool, service: Bool)

    private var detector: ConnectivityIncidentDetector
    private var outbox: ConnectivityIncidentOutbox
    private let file: URL?
    private let send: Send
    private let check: Check
    private let app: ConnectivityIncidentApp
    private let clock: any Clock<Duration>
    private let now: @Sendable () -> Date
    /// Whether the signed-in account is the cmux team's (connectivity telemetry's audience).
    private let isTeam: @MainActor () -> Bool
    /// Developer network simulations that are on now (`relay_only`, `block_udp`).
    public var simulations: [String] = []
    private var tickTask: Task<Void, Never>?
    private var flushTask: Task<Void, Never>?
    /// The one wait for the outbox head's backoff.
    private var retryTask: Task<Void, Never>?
    private var lastSave: Date = .distantPast
    private var lifecycleObservers: [any NSObjectProtocol] = []
    public static let tickInterval: Duration = .seconds(5)

    public init(file: URL?, app: ConnectivityIncidentApp = .current(), rules: ConnectivityIncidentDetector.Rules = .init(),
                clock: any Clock<Duration> = ContinuousClock(), now: @escaping @Sendable () -> Date = { Date() },
                isTeam: @escaping @MainActor () -> Bool = { ConnectivityTelemetry.shared.audience == .team },
                check: @escaping Check, send: @escaping Send) {
        detector = ConnectivityIncidentDetector(rules: rules)
        self.file = file
        self.app = app
        self.clock = clock
        self.now = now
        self.isTeam = isTeam
        self.check = check
        self.send = send
        outbox = file.flatMap { try? JSONDecoder().decode(ConnectivityIncidentOutbox.self, from: Data(contentsOf: $0)) } ?? .init()
        outbox.recoverRelaunch(at: now())
        save()
        flush()
    }

    /// Follows the app in front or not from UIKit itself (seeded with its state now), so the
    /// watch never depends on a scene observer reaching the coordinator: an incident is only for
    /// time the person had the app in front. The coordinator's own calls are then repeats.
    public func followApplicationState() {
        #if canImport(UIKit)
        guard lifecycleObservers.isEmpty else { return }
        let center = NotificationCenter.default
        lifecycleObservers = [
            center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.appActive(true) }
            },
            center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.appActive(false) }
            },
        ]
        appActive(UIApplication.shared.applicationState == .active)
        #endif
    }

    /// The file a signed-in account's reports wait in.
    public static func file(account: String) -> URL? {
        guard let base = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true) else { return nil }
        let safe = account.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? String($0) : "_" }.joined()
        return base.appending(path: "connectivity-incidents-\(safe).json")
    }

    /// What is waiting to be sent (tests, diagnostics).
    public var pending: [ConnectivityIncidentOutbox.Entry] { outbox.entries }

    // MARK: Inputs

    public func appActive(_ active: Bool) {
        if active != detector.isActive { log.info("app \(active ? "in front" : "in the background", privacy: .public)") }
        handle(detector.appActive(active, at: now()))
        if active { startTicking() } else { stopTicking() }
    }

    public func network(_ kind: String?) {
        handle(detector.network(kind, at: now()))
    }

    public func link(macID: String, name: String, _ state: ConnectivityIncidentDetector.LinkState) {
        handle(detector.link(macID: macID, name: name, state, at: now()))
    }

    public func dropped(macID: String, reason: String) {
        handle(detector.dropped(macID: macID, reason: reason, at: now()))
    }

    /// Time passed (the tick loop calls it; tests call it directly).
    public func tick() {
        handle(detector.tick(at: now()))
        // Open incidents' last-seen time, for relaunch recovery, at most every 30 s.
        if !outbox.open.isEmpty, now().timeIntervalSince(lastSave) >= 30 {
            let date = now()
            for id in outbox.open.keys { outbox.open[id]?.lastSeen = date }
            save()
        }
    }

    /// Sign-out (and the coordinator stopping): open incidents end now as `signed_out`.
    public func stop() {
        stopTicking()
        retryTask?.cancel()
        for observer in lifecycleObservers { NotificationCenter.default.removeObserver(observer) }
        lifecycleObservers = []
        handle(detector.appActive(false, at: now()).map { output in
            guard case .report(var incident) = output else { return output }
            incident.endReason = .signedOut
            return .report(incident)
        })
    }

    /// Before the account signs out, while its token still works: ends what is open and sends the
    /// outbox, waiting at most `limit`. What is not sent by then stays in the account's file for its
    /// next sign-in.
    public func signOut(within limit: Duration = .seconds(3)) async {
        stop()
        guard let flush = flushTask else { return }
        let clock = clock
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await flush.value }
            group.addTask { try? await clock.sleep(for: limit) }
            await group.next()
            group.cancelAll()
        }
    }

    // MARK: Running the detector

    /// Runs the detector's outputs. Only a team account checks (and so only it ever opens an
    /// incident); the end of an incident already reported is always queued, even after the audience
    /// changed, so no message stays "and counting".
    private func handle(_ outputs: [ConnectivityIncidentDetector.Output]) {
        guard !outputs.isEmpty else { return }
        var queued = false
        for output in outputs {
            switch output {
            case .check(let macID, let checkID):
                guard isTeam() else { continue }
                let check = check
                Task { [weak self] in
                    let result = await check()
                    guard let self else { return }
                    log.info("check for \(macID, privacy: .public): internet=\(result.internet) service=\(result.service)")
                    self.handle(self.detector.reachability(macID: macID, checkID: checkID, internet: result.internet,
                                                           service: result.service, at: self.now()))
                }
            case .report(let incident):
                log.notice("incident \(incident.kind.rawValue, privacy: .public) \(incident.state.rawValue, privacy: .public) mac=\(incident.macID, privacy: .public) after \(Int(incident.duration))s")
                ConnectivityTelemetry.shared.record(.link, "incident", outcome: incident.state == .open ? .failure : .info, fields: [
                    "kind": .code(incident.kind.rawValue), "state": .code(incident.state.rawValue),
                    "duration_s": .number(incident.duration.rounded()), "mac_id": .text(incident.macID),
                ])
                outbox.enqueue(incident, simulations: simulations, at: now())
                queued = true
            }
        }
        guard queued else { return }
        save()
        flush()
    }

    private func startTicking() {
        guard tickTask == nil else { return }
        let clock = clock
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await clock.sleep(for: Self.tickInterval) } catch { return }
                self?.tick()
            }
        }
    }

    private func stopTicking() {
        tickTask?.cancel()
        tickTask = nil
    }

    // MARK: Sending

    /// Sends the outbox in order until it is empty or its head must wait.
    private func flush() {
        guard flushTask == nil else { return }
        flushTask = Task { [weak self] in
            await self?.drain()
            self?.flushTask = nil
        }
    }

    private func drain() async {
        while let entry = outbox.next(at: now()) {
            let result: ConnectivityIncidentOutbox.Result
            do {
                try await send(entry.incident, entry.simulations, app)
                result = .sent
            } catch let failure as LiveAPI.Failure where [400, 403, 409, 413].contains(failure.status) {
                // A 404 is not here: a service that predates the route (a rollout) takes it later.
                log.error("incident report refused: \(failure.code, privacy: .public)")
                result = .refused
            } catch {
                log.info("incident report not sent yet: \(String(describing: error), privacy: .public)")
                result = .failed
            }
            outbox.finish(result, at: now())
            save()
            if result == .failed { break }
        }
        if let retryAt = outbox.retryAt {
            let wait = max(retryAt.timeIntervalSince(now()), 0.1)
            let clock = clock
            retryTask?.cancel()
            retryTask = Task { [weak self] in
                do { try await clock.sleep(for: .milliseconds(Int(wait * 1000))) } catch { return }
                self?.flush()
            }
        }
    }

    private func save() {
        guard let file else { return }
        // Nothing to keep and nothing kept: no file (everyone outside the team, tests).
        if outbox.entries.isEmpty, outbox.open.isEmpty, !FileManager.default.fileExists(atPath: file.path) { return }
        lastSave = now()
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(outbox) else { return }
        try? data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    // MARK: The live check

    /// Checks Apple's captive portal page (the same one iOS uses) for the internet, and the service's
    /// health route, at once, a few seconds each.
    public static func liveCheck(serviceBase: URL) -> Check {
        { @Sendable in
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 6
            configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            let session = URLSession(configuration: configuration)
            defer { session.finishTasksAndInvalidate() }
            async let internet: Bool = {
                guard let url = URL(string: "https://captive.apple.com/hotspot-detect.html"),
                      let (data, response) = try? await session.data(from: url) else { return false }
                return (response as? HTTPURLResponse)?.statusCode == 200 && String(decoding: data, as: UTF8.self).contains("Success")
            }()
            async let service: Bool = {
                guard let (_, response) = try? await session.data(from: serviceBase.appending(path: "v1/health")) else { return false }
                return (response as? HTTPURLResponse)?.statusCode == 200
            }()
            return await (internet, service)
        }
    }
}
