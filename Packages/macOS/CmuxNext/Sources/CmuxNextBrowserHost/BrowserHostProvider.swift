public import CmuxNextBrowser
public import CmuxNextBrowserAutomation
public import CmuxNextWakeups
public import Foundation
public import Observation
import os

/// The app side of the browser host's provider connection
/// (plans/cmux-next/browser-host.md, "Provider connection", step c3).
///
/// The app dials the host, proves the daemon's secret in `hello` with every
/// browser tab, and then serves the host: driver `call`s on WebKit tabs go
/// to the WebKit driver, `cdp` frames for CEF tabs go through the shim's raw
/// DevTools relay, and tab changes, extension access, driver events and a
/// person's input go back. Leases arrive as frames; the app shows them.
///
/// Everything runs on the main actor in frame order: a `lease` frame marks
/// its tab agent-driven before the next frame is read. When the link drops,
/// the provider reconnects when the credentials source reports new
/// credentials, or after a `Backoff` delay on the injected clock. It never
/// polls; with no credentials (before step c2) it stays idle.
@MainActor
@Observable
public final class BrowserHostProvider {
    public enum Status: Hashable, Sendable {
        /// No credentials, or stopped.
        case idle
        case connecting
        /// `hello` sent; the host may still refuse it.
        case connected
        case waitingToRetry
    }

    public internal(set) var status = Status.idle
    /// Leases the host announced, by tab id.
    public internal(set) var leases: [String: ProviderLease] = [:]
    /// The page agent bundle's fingerprint from the last `hello.ack`.
    public internal(set) var agentBundleSHA: String?

    /// A lease started, changed or ended on a tab (nil: ended).
    @ObservationIgnored public var onLeaseChange: ((String, ProviderLease?) -> Void)?
    /// The host's page agent bundle (`hello.ack`): source and fingerprint.
    @ObservationIgnored public var onAgentBundle: ((String, String) -> Void)?
    /// A tab the host knew left the app (`tab.gone` was sent).
    @ObservationIgnored public var onTabGone: ((String) -> Void)?

    @ObservationIgnored let identity: ProviderIdentity
    @ObservationIgnored weak var credentials: (any ProviderCredentialsSource)?
    @ObservationIgnored weak var tabSource: (any ProviderTabSource)?
    @ObservationIgnored weak var accessSource: (any ProviderAccessSource)?
    @ObservationIgnored weak var relay: (any ProviderDevToolsRelay)?
    @ObservationIgnored weak var marking: (any ProviderAgentMarking)?
    @ObservationIgnored let driver: (any DriverCallHandler)?
    @ObservationIgnored let clock: any Clock<Duration>
    @ObservationIgnored let dial: @Sendable (ProviderCredentials) async throws -> ProviderConnection
    /// How long `cdp.attach` may take to make a page ready (the host waits 10 s).
    @ObservationIgnored let prepareDeadline: Duration
    @ObservationIgnored let logger = Logger(subsystem: "com.cmuxterm.next", category: "browser-host-provider")

    @ObservationIgnored var backoff: Backoff
    @ObservationIgnored let retryTimer: DemandTimer
    @ObservationIgnored var generation = 0
    @ObservationIgnored var cycle: Task<Void, Never>?
    @ObservationIgnored var credentialCheck: Task<Void, Never>?
    @ObservationIgnored var eventsTask: Task<Void, Never>?
    @ObservationIgnored var connection: ProviderConnection?
    @ObservationIgnored var currentCredentials: ProviderCredentials?
    @ObservationIgnored var started = false

    // Tab and access state sent on the current connection (`+Tabs`).
    @ObservationIgnored var latestTabs: [ProviderTab] = []
    @ObservationIgnored var latestAccess: [String: ProviderTabAccess] = [:]
    @ObservationIgnored var announced: [String: ProviderTab] = [:]
    @ObservationIgnored var accessSent: [String: AccessKey] = [:]
    @ObservationIgnored var observation = 0
    @ObservationIgnored var calledTargets: Set<String> = []
    // CDP relays of the current connection (`+Relay`).
    @ObservationIgnored var relays: [String: RelaySession] = [:]
    @ObservationIgnored var relayGeneration = 0

    public init(identity: ProviderIdentity,
                credentials: any ProviderCredentialsSource,
                tabs: any ProviderTabSource,
                access: any ProviderAccessSource,
                driver: (any DriverCallHandler)?,
                relay: any ProviderDevToolsRelay,
                marking: any ProviderAgentMarking,
                clock: any Clock<Duration> = ContinuousClock(),
                backoff: Backoff = Backoff(initial: .milliseconds(250), maximum: .seconds(30)),
                prepareDeadline: Duration = .seconds(8),
                dial: @escaping @Sendable (ProviderCredentials) async throws -> ProviderConnection = { try await ProviderConnection.dial(path: $0.socketPath) }) {
        self.identity = identity
        self.credentials = credentials
        self.tabSource = tabs
        self.accessSource = access
        self.driver = driver
        self.relay = relay
        self.marking = marking
        self.clock = clock
        self.backoff = backoff
        retryTimer = DemandTimer(owner: "browser-host.provider-retry", clock: clock)
        self.prepareDeadline = prepareDeadline
        self.dial = dial
    }

    isolated deinit {
        cycle?.cancel()
        credentialCheck?.cancel()
        eventsTask?.cancel()
        retryTimer.cancel()
        connection?.close()
    }

    /// Starts watching tabs and driver events and connects when credentials exist.
    public func start() {
        guard !started else { return }
        started = true
        if let driver {
            let events = driver.events
            eventsTask = Task { [weak self] in
                for await event in events { self?.send(.event(name: event.name, payload: event.payload)) }
            }
        }
        observeTabs()
        connect()
    }

    /// Disconnects and stays idle until `start()` or `credentialsChanged()`.
    public func stop() {
        generation += 1
        cycle?.cancel()
        cycle = nil
        credentialCheck?.cancel()
        retryTimer.cancel()
        dropConnection(reason: "the provider stopped")
        status = .idle
    }

    /// The daemon connection changed or the host restarted: reconnect now
    /// when not connected, or when the credentials differ from the link's.
    public func credentialsChanged() {
        guard started else { return }
        guard status == .connected else {
            backoff.reset()
            connect()
            return
        }
        let gen = generation
        credentialCheck?.cancel()
        credentialCheck = Task { [weak self] in
            let fresh = await self?.credentials?.providerCredentials()
            guard let self, gen == self.generation, fresh != self.currentCredentials else { return }
            self.backoff.reset()
            self.connect()
        }
    }

    /// Re-reads the tab list (for state that is not observable: visibility,
    /// a page created or released).
    public func refreshTabs() { observeTabs() }

    /// A person pressed a key or clicked in a leased tab: the host pauses
    /// the lease. False when the tab has no lease or the link is down.
    @discardableResult
    public func reportUserInput(targetID: String) -> Bool {
        guard leases[targetID] != nil, connection != nil else { return false }
        send(.userInput(targetID: targetID))
        return true
    }

    // MARK: Connection lifecycle

    /// Starts a new connection attempt, replacing any current link.
    func connect() {
        generation += 1
        let gen = generation
        cycle?.cancel()
        retryTimer.cancel()
        dropConnection(reason: "reconnecting")
        status = .connecting
        cycle = Task { [weak self] in await self?.run(gen) }
    }

    private func run(_ gen: Int) async {
        guard let credentials = await credentials?.providerCredentials() else {
            if gen == generation { status = .idle }
            return
        }
        guard gen == generation else { return }
        let link: ProviderConnection
        do {
            link = try await dial(credentials)
        } catch {
            guard gen == generation else { return }
            logger.notice("browser host provider: dial failed: \(String(describing: error), privacy: .public)")
            scheduleRetry(gen)
            return
        }
        guard gen == generation else {
            link.close()
            return
        }
        currentCredentials = credentials
        connection = link
        link.start()
        sendHello(link, secret: credentials.secret)
        status = .connected
        var frames = link.frames.makeAsyncIterator()
        guard let first = await frames.next(), gen == generation, case .helloAck(let bundle, let sha) = first else {
            guard gen == generation else { return }
            logger.notice("browser host provider: no hello.ack (\(link.closeReason ?? "unexpected frame", privacy: .public))")
            dropConnection(reason: "no hello.ack")
            scheduleRetry(gen)
            return
        }
        backoff.reset()
        agentBundleSHA = sha
        onAgentBundle?(bundle, sha)
        while let frame = await frames.next() {
            guard gen == generation else { return }
            handle(frame)
        }
        guard gen == generation else { return }
        logger.notice("browser host provider: link closed (\(link.closeReason ?? "", privacy: .public))")
        dropConnection(reason: link.closeReason ?? "closed")
        scheduleRetry(gen)
    }

    private func scheduleRetry(_ gen: Int) {
        status = .waitingToRetry
        let delay = backoff.next()
        retryTimer.schedule(after: delay) { @MainActor [weak self] in
            guard let self, gen == self.generation else { return }
            self.connect()
        }
    }

    /// Ends the current link and forgets every per-link state (leases, relays).
    func dropConnection(reason: String) {
        guard let link = connection else { return }
        connection = nil
        link.close(reason: reason)
        for targetID in Array(relays.keys) { endRelay(targetID) }
        announced = [:]
        accessSent = [:]
        calledTargets = []
        let ended = leases.keys
        leases = [:]
        for targetID in ended { onLeaseChange?(targetID, nil) }
    }

    /// Queues a frame on the current link; dropped when there is none.
    func send(_ frame: ProviderFrame) {
        guard let connection else { return }
        do {
            try connection.send(frame)
        } catch {
            logger.error("browser host provider: \(frame.description, privacy: .public) not sent: \(String(describing: error), privacy: .public)")
            if case .result(let id, _, _) = frame {
                try? connection.send(.result(id: id, result: nil, error: DriverError(.invalid, "the result is too large to send").json))
            }
        }
    }

    private func sendHello(_ link: ProviderConnection, secret: ProviderSecret) {
        let tabs = latestTabs
        var hello = ProviderFrame.hello(version: ProviderCodec.version, providerID: identity.providerID,
                                        installID: identity.installID, secret: secret, engines: identity.engines,
                                        tabs: tabs.map(\.announce))
        // The host reads hello with a 1 MiB limit: a long tab list follows as events.
        let fits = ((try? ProviderCodec.encode(hello))?.count ?? Int.max) <= ProviderCodec.maxHelloBytes
        if !fits {
            hello = .hello(version: ProviderCodec.version, providerID: identity.providerID, installID: identity.installID,
                           secret: secret, engines: identity.engines, tabs: [])
        }
        send(hello)
        announced = [:]
        if fits { for tab in tabs { announced[tab.targetID] = tab } }
        accessSent = [:]
        sendTabChanges()
    }
}
