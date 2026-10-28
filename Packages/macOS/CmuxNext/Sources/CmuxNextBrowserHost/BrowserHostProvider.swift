public import AppKit
import CmuxNextBrowser
public import CmuxNextBrowserAutomation
public import CmuxNextWakeups
import Foundation
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
/// its tab agent-driven before the next frame is handled. Each frame is one
/// task of the automation class, posted as it is read
/// (``MainWorkScheduler/post(_:owner:file:line:_:)``, owner `browser-host.<tag>`):
/// an agent never competes with the person, so a frame
/// read while a key is pending runs after that key. Tasks of one class run in
/// post order. The post runs on the next main run loop turn, also while frames
/// run, not on a display frame: an agent's CDP and driver traffic is
/// sequential request and reply. Only pending input or the class's spent
/// budget holds it for a frame. The main actor only
/// dispatches; frames that leave the app (CDP replies, results) are id-mapped
/// and encoded on the link's write queue, off the main actor. The tab list is
/// read in automation-class tasks only. When the link drops,
/// the provider reconnects when the credentials source reports new
/// credentials, or after a `Backoff` delay (an automation-class, flexible ``MainDeadline``). It never
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

    /// Consumers of lease changes (`observeLeases`), in registration order.
    @ObservationIgnored var leaseObservers: [(id: UInt64, consumer: (String, ProviderLease?) -> Void)] = []
    @ObservationIgnored var nextLeaseObserverID: UInt64 = 0
    @ObservationIgnored var inputObservers: [(id: UInt64, consumer: (DriverJSON) -> Void)] = []
    @ObservationIgnored var nextInputObserverID: UInt64 = 0
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
    @ObservationIgnored weak var opener: (any ProviderTabOpening)?
    /// The tab nodes an agent's capture votes on (``ProviderCaptureVoting``); nil takes no votes.
    @ObservationIgnored weak var capture: (any ProviderCaptureVoting)?
    /// The app's Chromium Host, which relays agent CDP to the browser host by itself;
    /// nil (the default, and with feature `chromiumHostAgentRelay` off) relays every tab through the app.
    @ObservationIgnored public weak var relayLinking: (any ProviderRelayLinking)?
    /// The id this app gives its Chromium Host's relay link, once per launch: the browser host relays a tab on
    /// the link only when the app names this id for it, so a link of another app's host never gets its pages.
    @ObservationIgnored let relayLinkID = "link_" + UUID().uuidString.lowercased()
    @ObservationIgnored let driver: (any DriverCallHandler)?
    /// The app's main-thread scheduler: frame tasks and the tab observation run in its automation class.
    @ObservationIgnored let mainWork: MainWorkScheduler
    /// Where the retry and the relays' prepare deadlines are placed (on ``mainWork``'s queue).
    @ObservationIgnored let deadlines: MainDeadlineScheduler
    @ObservationIgnored let dial: @Sendable (ProviderCredentials) async throws -> ProviderConnection
    /// How long `cdp.attach` may take to make a page ready (the host waits 10 s).
    @ObservationIgnored let prepareDeadline: Duration
    @ObservationIgnored let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "browser-host-provider")

    @ObservationIgnored var backoff: Backoff
    @ObservationIgnored let retryTimer: MainDeadline
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
    /// ``followTabs()`` ran (`+Tabs`).
    @ObservationIgnored var followingTabs = false
    /// The owner of the tab list's automation tasks, interned once.
    @ObservationIgnored let tabsTaskOwner: MainTaskOwner
    /// The owner of the automation tasks that end a screenshot's capture vote at its reply, interned once.
    @ObservationIgnored let captureTaskOwner: MainTaskOwner
    @ObservationIgnored var calledTargets: Set<String> = []
    // CDP relays of the current connection (`+Relay`).
    @ObservationIgnored var relays: [String: RelaySession] = [:]
    @ObservationIgnored var relayGeneration = 0
    /// The next raw CDP id per tab, kept across relays and links: the host
    /// restarts its ids for every relay, and a late reply of an old relay
    /// must find no mapping. Entries stay after a tab closes on purpose
    /// (one Int per tab id; store tab ids are durable and never reused), so
    /// a tab id that comes back never restarts at 2^30.
    @ObservationIgnored var rawIDCursor: [String: Int] = [:]

    public init(identity: ProviderIdentity,
                credentials: any ProviderCredentialsSource,
                tabs: any ProviderTabSource,
                access: any ProviderAccessSource,
                driver: (any DriverCallHandler)?,
                relay: any ProviderDevToolsRelay,
                marking: any ProviderAgentMarking,
                mainWork: MainWorkScheduler,
                opener: (any ProviderTabOpening)? = nil,
                capture: (any ProviderCaptureVoting)? = nil,
                deadlines: MainDeadlineScheduler? = nil,
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
        self.opener = opener
        self.capture = capture
        self.mainWork = mainWork
        tabsTaskOwner = mainWork.board.owner("browser-host.tabs")
        captureTaskOwner = mainWork.board.owner("browser-host.capture")
        let deadlines = deadlines ?? MainDeadlineScheduler(work: mainWork)
        self.deadlines = deadlines
        self.backoff = backoff
        retryTimer = MainDeadline(owner: "browser-host.provider-retry", workClass: .automation, scheduler: deadlines)
        self.prepareDeadline = prepareDeadline
        self.dial = dial
    }

    // cx-t7hu: not an isolated deinit; its runtime hop traps when released inside an action's task-local scope.
    // Sendable cleanup only, so it runs on whatever thread releases the provider. The retry deadline needs no cancel:
    // a released MainDeadline never runs.
    nonisolated deinit {
        cycle?.cancel()
        credentialCheck?.cancel()
        eventsTask?.cancel()
        connection?.close()
    }

    /// Starts watching tabs and driver events and connects when credentials exist.
    public func start() {
        guard !started else { return }
        started = true
        if let driver {
            let events = driver.events
            // main-hop-allow: the driver emits its events on main; the loop only hands each to the link's write queue (send encodes off main), in emit order with the call replies the same actor sends
            eventsTask = Task { [weak self] in
                for await event in events { self?.send(.event(name: event.name, payload: event.payload)) }
            }
        }
        followTabs()
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
        relayLinking?.setRelayLink(nil)
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
        // main-hop-allow: providerCredentials is the app's main-actor async source (the daemon's answer); the task only compares it and reconnects
        credentialCheck = Task { [weak self] in
            let fresh = await self?.credentials?.providerCredentials()
            guard let self, gen == self.generation, fresh != self.currentCredentials else { return }
            self.backoff.reset()
            self.connect()
        }
    }

    /// Re-reads the tab list (for state that is not observable: visibility,
    /// a page created or released).
    public func refreshTabs() { readTabsNow() }

    /// A person pressed a key or clicked in tab `targetID`: when the tab is
    /// leased, the host pauses the lease. Call only from the app's own event
    /// dispatch (never from driver or agent input). False when the event
    /// does not count, the tab has no lease, or the link is down.
    @discardableResult
    public func reportUserInput(event: NSEvent, synthetic: Bool = false, targetID: String) -> Bool {
        guard ProviderUserInput.pausesLease(event, synthetic: synthetic), leases[targetID] != nil, connection != nil else { return false }
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
        // main-hop-allow: the link's life: it awaits the main-actor credential source and the link's frames, and each frame it reads becomes one automation task (post)
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
        // The host proves itself before the secret leaves the app: a
        // same-uid process that took the socket path first gets nothing.
        guard let peer = link.peerPID, credentials.acceptsPeer(peer) else {
            logger.error("browser host provider: the socket's peer is not the browser host; hello not sent")
            link.close(reason: "the socket's peer is not the browser host")
            scheduleRetry(gen)
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
        // The host serves this app now: its Chromium Host may open the relay link (only the derived credential).
        relayLinking?.setRelayLink(Self.relayLink(credentials, linkID: relayLinkID))
        while let frame = await frames.next() {
            guard gen == generation else { return }
            post(frame, from: link)
        }
        guard gen == generation else { return }
        logger.notice("browser host provider: link closed (\(link.closeReason ?? "", privacy: .public))")
        dropConnection(reason: link.closeReason ?? "closed")
        scheduleRetry(gen)
    }

    /// Queues `frame` as one automation-class task. A frame of a link that dropped or was replaced
    /// before its task ran is not handled (its replies would have no link).
    private func post(_ frame: ProviderFrame, from link: ProviderConnection) {
        guard let task = Self.task(for: frame) else { return }
        // node-free: an agent drives tabs nobody sees; its commands run while hidden.
        mainWork.post(.automation, owner: task.owner) { [weak self] in
            guard let self, self.connection === link else { return }
            task.run(self)
        }
    }

    private func scheduleRetry(_ gen: Int) {
        status = .waitingToRetry
        let delay = backoff.next()
        retryTimer.schedule(after: delay) { [weak self] in
            guard let self, gen == self.generation else { return }
            self.connect()
        }
    }

    /// Ends the current link and forgets every per-link state (leases, relays).
    func dropConnection(reason: String) {
        guard let link = connection else { return }
        connection = nil
        link.close(reason: reason)
        // The browser host ends the Chromium Host's relay link with this connection; the next `hello.ack`
        // gives it again, so the host dials the same browser host anew after a reconnect.
        relayLinking?.setRelayLink(nil)
        for targetID in Array(relays.keys) { endRelay(targetID) }
        announced = [:]
        accessSent = [:]
        calledTargets = []
        let ended = leases.keys
        leases = [:]
        for targetID in ended { notifyLease(targetID, nil) }
    }

    /// Queues a frame on the current link; dropped when there is none. Encoded on the link's
    /// write queue, off the main actor.
    func send(_ frame: ProviderFrame) {
        connection?.send(frame)
    }

    /// Queues the frames `build` makes on the link's write queue, in order with every other send
    /// (a CDP reply's id rewrite runs there, off the main actor).
    func send(building build: @escaping @Sendable () -> [ProviderFrame]) {
        connection?.send(building: build)
    }

    /// The Chromium Host's relay link for a connection's `credentials`: their socket and peer pids, and the
    /// credential derived from their secret (``ProviderSecret/relayCredential``), never the secret.
    nonisolated static func relayLink(_ credentials: ProviderCredentials, linkID: String) -> ChromiumHostRelayLink {
        ChromiumHostRelayLink(socketPath: credentials.socketPath, credential: credentials.secret.relayCredential.value,
                              linkID: linkID, hostPID: credentials.hostPID, listenerPID: credentials.listenerPID ?? 0)
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
