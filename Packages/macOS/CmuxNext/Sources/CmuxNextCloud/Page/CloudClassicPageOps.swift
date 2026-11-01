public import Foundation
import Observation

/// The Cloud page's ops on the classic `/api/vm` link (``CloudConfiguration/LinkSource/legacy``, the
/// release and default path).
///
/// The Cloud app server reaches its backend only through the host credential relay, and the relay
/// registers on the app server link path alone (cx-t2rz P3-1). On the classic path every page op
/// came back `relay_unavailable`, so the page sat on "Cloud is not available until cmux
/// reconnects." with a Retry that could never succeed, while the CLI and the sidebar listed the
/// machines. These ops answer the page from what the CLI and the sidebar read: the app's sign-in
/// and its `/api/vm` list (the app passes them as a ``Backend``).
///
/// - Reads: `cloud.auth.status`, `cloud.machine.list`, `cloud.machine.watch`, and `cloud.plan.get`
///   when the list carried the plan's machine cap.
/// - Mutations run the app's classic calls: start (resume), pause, rename; delete only for the
///   person (`byPerson`: origin `user`, after the native sheet), as the app server allows.
/// - While Cloud is unavailable (``Backend/unavailable``: turned off by the organization, no
///   managed team, a local-only backend) every op but `cloud.auth.status` is refused
///   `cmux.cloud.unavailable` with the reason, and the feed lists no machine: the same gate the
///   app's own calls pass.
/// - Any other op, create included (the page's create is not one of its confirmed ops, so it never
///   reaches here), is refused `cmux.cloud.unsupported`: the page shows it as not available.
/// - Live state: while a feed listens, an observation of the backend's machines (no timer) turns
///   each change, from a refresh, the CLI or the sidebar, into `upsert` and `removed` events at a
///   new revision. It ends with the last listener.
@MainActor
public final class CloudClassicPageOps {
    /// What the ops read and run.
    public struct Backend {
        public var signedIn: @MainActor () -> Bool
        public var team: @MainActor () -> String?
        /// Why Cloud cannot run now, as a person reads it, or nil (observable: the feed watches it).
        public var unavailable: @MainActor () -> String?
        /// The listed machines in sidebar order (observable: the feed watches it).
        public var machines: @MainActor () -> [CloudMachine]
        public var limits: @MainActor () -> CloudMachineLimits?
        /// Whether a list for the account signed in now has landed.
        public var hasList: @MainActor () -> Bool
        /// The last list failure, as a person reads it.
        public var lastError: @MainActor () -> String?
        public var refresh: @MainActor () async -> Void
        public var resume: @MainActor (String) async throws -> Void
        public var pause: @MainActor (String) async throws -> Void
        public var rename: @MainActor (String, String) async throws -> Void
        public var delete: @MainActor (String) async throws -> Void
        /// A classic call's error as the page's refusal.
        public var refusal: @MainActor (any Error) -> Refusal
        /// What a signed-out op answers, as a person reads it.
        public var signInFirst: String

        public init(signedIn: @escaping @MainActor () -> Bool, team: @escaping @MainActor () -> String?,
                    unavailable: @escaping @MainActor () -> String?,
                    machines: @escaping @MainActor () -> [CloudMachine], limits: @escaping @MainActor () -> CloudMachineLimits?,
                    hasList: @escaping @MainActor () -> Bool, lastError: @escaping @MainActor () -> String?,
                    refresh: @escaping @MainActor () async -> Void, resume: @escaping @MainActor (String) async throws -> Void,
                    pause: @escaping @MainActor (String) async throws -> Void, rename: @escaping @MainActor (String, String) async throws -> Void,
                    delete: @escaping @MainActor (String) async throws -> Void,
                    refusal: @escaping @MainActor (any Error) -> Refusal, signInFirst: String) {
            self.signedIn = signedIn
            self.team = team
            self.unavailable = unavailable
            self.machines = machines
            self.limits = limits
            self.hasList = hasList
            self.lastError = lastError
            self.refresh = refresh
            self.resume = resume
            self.pause = pause
            self.rename = rename
            self.delete = delete
            self.refusal = refusal
            self.signInFirst = signInFirst
        }
    }

    /// An op the page cannot have: its `cmux.cloud.<reason>` code and the message.
    public nonisolated struct Refusal: Error, Equatable, Sendable {
        public var code: String
        public var message: String
        /// The refusal's details the page reads (a plan refusal's `plan`).
        public var details: [String: String]

        public init(code: String, message: String, details: [String: String] = [:]) {
            self.code = code
            self.message = message
            self.details = details
        }
    }

    /// The op params the ops read (the page's snake_case).
    public nonisolated struct Args: Decodable, Sendable {
        public var machine: String?
        public var name: String?

        public init(machine: String? = nil, name: String? = nil) {
            self.machine = machine
            self.name = name
        }
    }

    /// One machine as the page's `CloudMachine` record (contract 1.2's snake_case).
    public nonisolated struct Record: Encodable, Sendable, Equatable {
        public struct Size: Encodable, Sendable, Equatable {
            public var cpu: Int?
            public var memory_mb: Int?
            public var disk_mb: Int?
        }

        public struct Image: Encodable, Sendable, Equatable {
            public var id: String
        }

        public struct IdlePolicy: Encodable, Sendable, Equatable {
            public var idle_seconds: Int
        }

        public var id: String
        public var status: String
        public var name: String?
        public var size: Size?
        public var image: Image?
        /// Epoch milliseconds.
        public var created_at: Double?
        public var idle_policy: IdlePolicy?
        /// The revision the record last changed at: a decimal string that only grows.
        public var revision: String

        init(_ machine: CloudMachine, revision: Int) {
            id = machine.id
            status = switch machine.shownStatus {
            case .provisioning: "provisioning"
            case .running: "running"
            case .paused: "paused"
            case .pausing: "pausing"
            case .starting: "starting"
            case .deleting: "deleting"
            case .failed: "failed"
            case .destroyed: "deleting"
            case .unknown: "unknown"
            }
            // The sidebar's name (the generated slug when the user gave none), never a second rule.
            name = machine.shownName
            size = machine.size.map { Size(cpu: $0.cpu, memory_mb: $0.memoryMb, disk_mb: $0.storageMb) }
            image = machine.image.map(Image.init(id:))
            created_at = machine.createdAt.map { ($0.timeIntervalSince1970 * 1000).rounded() }
            idle_policy = machine.idlePauseMinutes.map { IdlePolicy(idle_seconds: $0 * 60) }
            self.revision = String(revision)
        }
    }

    /// One watch event (`cmux.cloud.machine.watch`).
    public nonisolated struct Event: Encodable, Sendable, Equatable {
        public var type: String
        public var revision: Int
        public var machine: Record?
        public var id: String?
    }

    /// An op's answer, encoded as the page reads it.
    public nonisolated enum Answer: Encodable, Sendable, Equatable {
        case auth(signedIn: Bool, team: String?)
        case list(machines: [Record], revision: Int)
        case revision(Int)
        case plan(Plan)
        case machine(Record, revision: Int)
        case deleted

        public func encode(to encoder: any Encoder) throws {
            switch self {
            case let .auth(signedIn, team): try Auth(signedIn: signedIn, team: team).encode(to: encoder)
            case let .list(machines, revision): try List(machines: machines, revision: revision).encode(to: encoder)
            case let .revision(revision): try Watch(revision: revision).encode(to: encoder)
            case let .plan(plan): try plan.encode(to: encoder)
            case let .machine(record, revision): try Changed(machine: record, revision: revision).encode(to: encoder)
            case .deleted: try Deleted().encode(to: encoder)
            }
        }

        struct Auth: Encodable { var signedIn: Bool; var team: String? }
        struct List: Encodable { var machines: [Record]; var revision: Int }
        struct Watch: Encodable { var revision: Int }
        struct Changed: Encodable { var machine: Record; var revision: Int }
        struct Deleted: Encodable { var deleted = true }
    }

    /// `CloudPlan` as the classic list knows it: the cap and how many machines run.
    public nonisolated struct Plan: Encodable, Sendable, Equatable {
        public struct Limits: Encodable, Sendable, Equatable {
            public var max_active: Int
            public var max_saved: Int
            public var memory_options_mb: [Int]
            public var locked_memory_options_mb: [Int]
        }

        public struct Usage: Encodable, Sendable, Equatable {
            public var active: Int
            public var saved: Int
        }

        public var plan_id: String
        public var limits: Limits
        public var usage: Usage
    }

    private let backend: Backend
    /// The projection revision: one more for each change the page saw.
    public private(set) var revision = 0
    /// Each machine the page saw and the revision it last changed at.
    private var known: [String: (machine: CloudMachine, revision: Int)] = [:]
    private var order: [String] = []
    private var listeners: [UUID: @MainActor (Event) -> Void] = [:]
    private var observing = false

    public init(backend: Backend) {
        self.backend = backend
    }

    /// Live feed listeners.
    public var listenerCount: Int { listeners.count }

    /// Starts sending watch events to `emit`; the returned closure stops it.
    public func feed(_ emit: @escaping @MainActor (Event) -> Void) -> () -> Void {
        let id = UUID()
        listeners[id] = emit
        if !observing { observe() }
        return { [weak self] in self?.listeners[id] = nil }
    }

    /// Runs the page op `op` (`cloud.<…>`, the server's name).
    public func run(_ op: String, args: Args, byPerson: Bool) async throws -> Answer {
        if op == "cloud.auth.status" {
            let signedIn = backend.signedIn()
            return .auth(signedIn: signedIn, team: signedIn ? backend.team() : nil)
        }
        guard backend.signedIn() else { throw Refusal(code: "cmux.cloud.auth_required", message: backend.signInFirst) }
        if let reason = backend.unavailable() { throw Refusal(code: "cmux.cloud.unavailable", message: reason) }
        switch op {
        case "cloud.machine.list":
            if !backend.hasList() { await backend.refresh() }
            if !backend.hasList(), let error = backend.lastError() { throw Refusal(code: "cmux.cloud.failed", message: error) }
            sync()
            return .list(machines: order.compactMap { id in known[id].map { Record($0.machine, revision: $0.revision) } }, revision: revision)
        case "cloud.machine.watch":
            sync()
            return .revision(revision)
        case "cloud.plan.get":
            return .plan(try plan())
        case "cloud.machine.start":
            return try await change(args) { try await self.backend.resume($0) }
        case "cloud.machine.pause":
            return try await change(args) { try await self.backend.pause($0) }
        case "cloud.machine.rename":
            let name = args.name ?? ""
            return try await change(args) { try await self.backend.rename($0, name) }
        case "cloud.machine.delete":
            guard byPerson else { throw Refusal(code: "cmux.cloud.forbidden", message: op) }
            let id = try machineID(args)
            try await mapped { try await self.backend.delete(id) }
            sync()
            return .deleted
        default:
            throw Refusal(code: "cmux.cloud.unsupported", message: op)
        }
    }

    /// Runs `action` on the args' machine, then answers its record at the revision it reached.
    private func change(_ args: Args, _ action: @MainActor (String) async throws -> Void) async throws -> Answer {
        let id = try machineID(args)
        try await mapped { try await action(id) }
        sync()
        guard let entry = known[id] else { throw Refusal(code: "cmux.cloud.not_found", message: id) }
        return .machine(Record(entry.machine, revision: entry.revision), revision: revision)
    }

    private func machineID(_ args: Args) throws -> String {
        guard let id = args.machine, !id.isEmpty else { throw Refusal(code: "cmux.cloud.invalid", message: "machine") }
        guard backend.machines().contains(where: { $0.id == id }) else { throw Refusal(code: "cmux.cloud.not_found", message: id) }
        return id
    }

    /// The list's cap and how many run; no cap or no list: not served. The classic list names no
    /// snapshot allowance, so none is counted.
    private func plan() throws -> Plan {
        guard let limits = backend.limits(), let cap = limits.maxActiveVms else {
            throw Refusal(code: "cmux.cloud.unsupported", message: "cloud.plan.get")
        }
        return Plan(plan_id: limits.planId ?? "",
                    limits: .init(max_active: cap, max_saved: 0, memory_options_mb: limits.memoryOptionsMb,
                                  locked_memory_options_mb: (limits.lockedMemoryOptionsMb ?? []).sorted()),
                    usage: .init(active: limits.activeVmCount, saved: 0))
    }

    /// Brings ``known`` up to the backend: each new or changed machine is an `upsert`, each gone one
    /// a `removed`, all at one new revision, sent to every listener. While Cloud is unavailable the
    /// page sees no machine.
    private func sync() {
        let machines = backend.unavailable() == nil ? backend.machines().filter { $0.status != .destroyed } : []
        let next = revision + 1
        var events: [Event] = []
        for machine in machines where known[machine.id]?.machine != machine {
            known[machine.id] = (machine, next)
            events.append(Event(type: "upsert", revision: next, machine: Record(machine, revision: next)))
        }
        let ids = Set(machines.map(\.id))
        for id in known.keys.sorted() where !ids.contains(id) {
            known[id] = nil
            events.append(Event(type: "removed", revision: next, id: id))
        }
        order = machines.map(\.id)
        guard !events.isEmpty else { return }
        revision = next
        for event in events {
            for listener in listeners.values { listener(event) }
        }
    }

    /// Re-arms one observation of the backend's machines and availability while a listener is left; each change
    /// syncs once it applied (the hop runs after the mutation).
    private func observe() {
        guard !listeners.isEmpty else {
            observing = false
            return
        }
        observing = true
        withObservationTracking {
            _ = backend.machines()
            _ = backend.unavailable()
        } onChange: { [weak self] in
            // task-owner: one hop per observed change, re-arms itself; ends with the last listener
            Task { @MainActor in
                self?.observe()
                self?.sync()
            }
        }
    }

    /// Runs `body`, turning a classic call's error into the page's refusal.
    private func mapped<T>(_ body: () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch let refusal as Refusal {
            throw refusal
        } catch {
            throw backend.refusal(error)
        }
    }
}
