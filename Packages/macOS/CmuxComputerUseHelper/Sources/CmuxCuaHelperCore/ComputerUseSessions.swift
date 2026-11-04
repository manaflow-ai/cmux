// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import os

/// The driver side the sessions need: upstream Cua Driver in production
/// (`CuaDriverRuntime`), a fake in tests.
public protocol CuaDriverSessionFactory: Sendable {
    /// The driver's tool inventory (`tools/list`).
    func inventory() throws -> Data
    /// A trusted upstream session (`cua_driver_session_create_v1` options).
    func createSession(options: Data) throws -> any CuaDriverSessionInvoking
}

/// One trusted upstream session handle.
public protocol CuaDriverSessionInvoking: Sendable {
    func invoke(name: String, arguments: Data) async throws -> Data
    /// Revokes the handle; idempotent.
    func destroy()
}

/// What the helper socket serves: the inventory, and one agent session per
/// admitted connection.
public protocol AgentSessionProviding: Sendable {
    func listTools() async throws -> Data
    /// Called at admission, before the admitted reply. A throw refuses the connection.
    func openSession() throws -> any AgentSessionServing
}

/// One admitted connection's session. Its authority is the connection: no
/// request field names a session or a mode.
public protocol AgentSessionServing: Sendable {
    /// `session/hello` labels, for the approval card only.
    func hello(_ labels: SessionLabels)
    func invoke(name: String, arguments: Data) async throws -> Data
    /// The connection closed.
    func close()
}

/// Sessions over a plain `ToolInvoking` (no upstream sessions): every
/// connection shares the tools. For tests and stand-ins.
public struct SharedToolSessions: AgentSessionProviding {
    let tools: any ToolInvoking

    public init(tools: any ToolInvoking) { self.tools = tools }

    public func listTools() async throws -> Data { try await tools.listTools() }

    public func openSession() throws -> any AgentSessionServing { Session(tools: tools) }

    struct Session: AgentSessionServing {
        let tools: any ToolInvoking
        func hello(_ labels: SessionLabels) {}
        func invoke(name: String, arguments: Data) async throws -> Data {
            try await tools.invoke(name: name, arguments: arguments)
        }

        func close() {}
    }
}

/// Upstream sessions per agent session (docs/computer-use-approvals.md,
/// "Sessions" and "The approval question"). Each call:
/// 1. the target guard resolves every app the call targets and refuses the
///    never-allowed ones (`CuaTargetPolicy`), without asking;
/// 2. under `ask`, an app outside the session's manifest is asked about
///    (`AppApprovalBroker`); "deny", no answer in time or no collector
///    refuses the call;
/// 3. machine consent (`ConsentGate`) runs last, after every other await;
/// 4. the call runs on the session's upstream handle, which is replaced
///    between calls when the manifest's apps change ("once" runs on a
///    one-call handle).
public final class ComputerUseSessions: AgentSessionProviding {
    let driver: any CuaDriverSessionFactory
    let configuration: ComputerUseConfiguration
    let broker: AppApprovalBroker
    let gate: ConsentGate
    let targetGuard: CuaTargetGuard
    let manifests: ManifestStore
    /// Discovery before approval (D21): metadata-only `list_apps` / `list_windows`.
    let discovery: DesktopDiscovery
    /// The `bounded` owner's manifest apps and display grant (nil: unreadable as JSON, or not bounded).
    let ownerManifest: OwnerManifestFacts?
    /// Monotonic seconds, for the session lifetime and idle limits.
    let clock: @Sendable () -> TimeInterval
    private let inventoryCache = OSAllocatedUnfairLock<Data?>(initialState: nil)

    public convenience init(driver: any CuaDriverSessionFactory, configuration: ComputerUseConfiguration,
                            broker: AppApprovalBroker, gate: ConsentGate, manifests: ManifestStoreLocation,
                            allowedTargetBundleIDs: String = "", hostBundleID: String? = nil) {
        self.init(driver: driver, configuration: configuration, broker: broker, gate: gate,
                  targetGuard: CuaTargetGuard(policy: CuaTargetPolicy(allowedBundleIDs: allowedTargetBundleIDs,
                                                                      hostBundleID: hostBundleID),
                                              resolver: MacCuaTargetResolver()),
                  manifests: ManifestStore(directory: manifests.directory))
    }

    init(driver: any CuaDriverSessionFactory, configuration: ComputerUseConfiguration, broker: AppApprovalBroker,
         gate: ConsentGate, targetGuard: CuaTargetGuard, manifests: ManifestStore,
         desktop: any DesktopEnumerating = MacDesktopEnumerator(),
         clock: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.discovery = DesktopDiscovery(enumerator: desktop, policy: targetGuard.policy)
        self.ownerManifest = configuration.mode == .bounded ? OwnerManifestFacts(path: configuration.ownerManifestPath) : nil
        self.driver = driver
        self.configuration = configuration
        self.broker = broker
        self.gate = gate
        self.targetGuard = targetGuard
        self.manifests = manifests
        self.clock = clock
    }

    public func listTools() async throws -> Data { try inventory() }

    func inventory() throws -> Data {
        if let cached = inventoryCache.withLockUnchecked({ $0 }) { return cached }
        let data = try driver.inventory()
        inventoryCache.withLockUnchecked { $0 = data }
        return data
    }

    /// One connection's session, with its upstream handle created now.
    public func openSession() throws -> any AgentSessionServing {
        let session = AgentSession(owner: self, id: AppApprovalBroker.nonce())
        broker.openSession(session.id)
        do {
            try session.start()
        } catch {
            broker.endSession(session.id)
            throw error
        }
        return session
    }
}

/// One admitted connection's agent session.
final class AgentSession: AgentSessionServing {
    /// One upstream handle, destroyed when the last call using it ends
    /// after it is replaced, or when the session closes.
    final class Handle: Sendable {
        let session: any CuaDriverSessionInvoking
        /// The app keys its manifest lists.
        let apps: Set<String>
        init(session: any CuaDriverSessionInvoking, apps: Set<String>) {
            self.session = session
            self.apps = apps
        }

        deinit { session.destroy() }
    }

    struct State {
        var handle: Handle?
        var generation = 0
        /// Start of the current grant period (the session lifetime), and the last call.
        var periodStart: TimeInterval
        var lastUse: TimeInterval
        var closed = false
    }

    let id: String
    private let owner: ComputerUseSessions
    private let state: OSAllocatedUnfairLock<State>

    init(owner: ComputerUseSessions, id: String) {
        self.owner = owner
        self.id = id
        let now = owner.clock()
        state = OSAllocatedUnfairLock(initialState: State(periodStart: now, lastUse: now))
    }

    /// Creates the first upstream handle (admission).
    func start() throws {
        _ = try handle(extra: [])
    }

    func hello(_ labels: SessionLabels) { owner.broker.label(id, labels) }

    func close() {
        let handle = state.withLockUnchecked { state -> Handle? in
            state.closed = true
            defer { state.handle = nil }
            return state.handle
        }
        // Revoke now, even while a call still holds the handle; then cancel its questions.
        handle?.session.destroy()
        owner.broker.endSession(id)
    }

    func invoke(name: String, arguments: Data) async throws -> Data {
        let checked = try await owner.targetGuard.resolve(name: name, arguments: arguments)
        var once: [ApprovalApp] = []
        let ask = owner.configuration.mode == .ask
        if ask, ReviewedTools.risk[name] != nil { expireIfNeeded() }
        let discovery = discoveryCall(name: name, arguments: checked.arguments, targets: checked.targets)
        if discovery == nil, ask, let risk = ReviewedTools.risk[name] {
            // An unreviewed tool is refused by upstream whatever the manifest says: nothing to ask.
            for target in checked.targets {
                let app = ApprovalApp(bundleID: target.bundleID, name: target.name)
                if try await approve(app, tool: name, risk: risk) { once.append(app) }
            }
        }
        // Read before the consent answer, so no await follows it.
        _ = try owner.inventory()
        let requirement = await owner.gate.requirement(for: name) { try self.owner.inventory() }
        try await owner.gate.admit(name, requirement: requirement)
        if let discovery { return owner.discovery.answer(discovery) }
        let handle = try handle(extra: once)
        return try await handle.session.invoke(name: name, arguments: checked.arguments)
    }

    /// The discovery call the worker answers itself (D21), or nil when
    /// upstream answers: always under standard and unrestricted, under
    /// bounded when the owner's manifest grants the display or cannot be
    /// read, and for `list_windows` of an app this session may use.
    private func discoveryCall(name: String, arguments: Data, targets: [CuaTargetIdentity]) -> DesktopDiscovery.Call? {
        guard name == "list_apps" || name == "list_windows" else { return nil }
        let granted: (CuaTargetIdentity) -> Bool
        switch owner.configuration.mode {
        case .ask:
            let keys = Set(owner.broker.allowedApps(id).map(\.key))
            granted = { keys.contains(ApprovalApp(bundleID: $0.bundleID, name: $0.name).key) }
        case .bounded:
            // A bounded owner decides which tools exist: one its manifest does not allow goes to
            // upstream, which refuses it.
            guard let manifest = owner.ownerManifest, !manifest.display, manifest.tools.contains(name) else { return nil }
            granted = { manifest.bundleIDs.contains($0.bundleID.lowercased()) }
        case .standard, .unrestricted:
            return nil
        }
        let object = HelperWire.object(arguments) ?? [:]
        let pid = (object["pid"] as? NSNumber).flatMap { Int32(exactly: $0.int64Value) }
        switch (name, pid, targets.count) {
        case ("list_apps", _, 0): return .apps
        case ("list_windows", nil, 0): return .windows(pid: nil)
        case ("list_windows", let pid?, 1) where !granted(targets[0]): return .windows(pid: pid)
        default: return nil
        }
    }

    /// Asks until `app` is allowed for this call. True when it is allowed
    /// for this call only.
    private func approve(_ app: ApprovalApp, tool: String, risk: String) async throws -> Bool {
        while true {
            switch owner.broker.allowance(id, app) {
            case .granted: return false
            case .once: return true
            case .none: break
            }
            switch await owner.broker.ask(session: id, app: app, tool: tool, risk: risk) {
            case .decided(.once): return true
            case .decided(.session), .decided(.always), .retry: continue
            case .decided(.deny): throw AppApprovalRefusal(code: .denied, app: app.name, tool: tool)
            case .timeout: throw AppApprovalRefusal(code: .timeout, app: app.name, tool: tool)
            case .unavailable, .ended: throw AppApprovalRefusal(code: .unavailable, app: app.name, tool: tool)
            }
        }
    }

    /// The session's grants last the session lifetime (8 h) and lapse after
    /// 30 min without a call, as its upstream handle does; then the session
    /// starts over with the saved list only.
    private func expireIfNeeded() {
        let now = owner.clock()
        let expired = state.withLockUnchecked { state -> Bool in
            let expired = now - state.periodStart >= TimeInterval(ComputerUseConfiguration.sessionLifetimeSeconds)
                || now - state.lastUse >= TimeInterval(ComputerUseConfiguration.idleSeconds)
            if expired {
                state.periodStart = now
                state.handle = nil
            }
            state.lastUse = now
            return expired
        }
        if expired { owner.broker.resetGrants(id) }
    }

    /// The handle for a call: the session's, replaced when its apps differ
    /// from the manifest's, or a one-call handle that adds `extra`.
    private func handle(extra: [ApprovalApp]) throws -> Handle {
        let configuration = owner.configuration
        let now = owner.clock()
        let apps = configuration.mode == .ask ? owner.broker.allowedApps(id) : []
        let keys = Set(apps.map(\.key))
        let plan = try state.withLockUnchecked { state -> (reuse: Handle?, generation: Int, remaining: Int) in
            guard !state.closed else { throw ToolError("the Computer Use session ended") }
            if configuration.mode != .ask {
                // Expired upstream handles start over in place, as under ask.
                if now - state.periodStart >= TimeInterval(ComputerUseConfiguration.sessionLifetimeSeconds)
                    || now - state.lastUse >= TimeInterval(ComputerUseConfiguration.idleSeconds) {
                    state.periodStart = now
                    state.handle = nil
                }
                state.lastUse = now
            }
            if extra.isEmpty, let handle = state.handle, handle.apps == keys { return (handle, 0, 0) }
            state.generation += 1
            let remaining = ComputerUseConfiguration.sessionLifetimeSeconds - Int(now - state.periodStart)
            return (nil, state.generation, remaining)
        }
        if let reuse = plan.reuse { return reuse }
        let all = apps + extra.filter { !keys.contains($0.key) }
        let created = try createHandle(apps: all, generation: plan.generation, remaining: plan.remaining)
        guard extra.isEmpty else { return created }
        return try state.withLockUnchecked { state in
            guard !state.closed else {
                created.session.destroy()
                throw ToolError("the Computer Use session ended")
            }
            // A newer handle wins when two calls replaced it at once.
            if let current = state.handle, current.apps == created.apps { return current }
            state.handle = created
            return created
        }
    }

    private func createHandle(apps: [ApprovalApp], generation: Int, remaining: Int) throws -> Handle {
        let configuration = owner.configuration
        let publicSession = "cmux-\(id)-\(generation)"
        var manifestPath: String?
        var temporary: String?
        switch configuration.mode {
        case .ask:
            let tools = CapabilityManifest.allowedTools(inventory: try owner.inventory())
            let manifest = CapabilityManifest(tools: tools, apps: apps, expiresAfterSeconds: remaining,
                                              idleTimeoutSeconds: ComputerUseConfiguration.idleSeconds)
            let path = try owner.manifests.write(manifest.data, name: publicSession + ".json")
            manifestPath = path
            temporary = path
        case .bounded:
            manifestPath = configuration.ownerManifestPath
        case .standard, .unrestricted:
            break
        }
        defer { if let temporary { owner.manifests.remove(temporary) } }
        let options = configuration.sessionOptions(publicSession: publicSession, lifetimeSeconds: remaining,
                                                   manifestPath: manifestPath)
        return Handle(session: try owner.driver.createSession(options: options), apps: Set(apps.map(\.key)))
    }
}
