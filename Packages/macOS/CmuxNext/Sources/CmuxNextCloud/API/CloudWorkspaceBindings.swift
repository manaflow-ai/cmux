public import Foundation

/// Native workspace identities verified by the owner API. Persisted beside the app's move ledger,
/// so a restart never mistakes a retired provider row for the workspace's logical machine.
@MainActor
public final class CloudWorkspaceBindings {
    public struct Scope: Codable, Hashable, Sendable {
        public let user: String
        public let team: String?
        public let origin: String
        public init(user: String, team: String?, origin: String) {
            self.user = user; self.team = team; self.origin = origin
        }
    }

    public struct Binding: Codable, Equatable, Sendable {
        public let scope: Scope
        public let workspace: String
        public let machine: String
        /// Previously verified carrier rows are hidden too, even while provider cleanup retries.
        public var targets: Set<String>
    }

    public var defaults: @MainActor () -> UserDefaults? = { nil }
    private let key: String
    private var memory: [Binding] = []

    public init(key: String = "cmux.cloud.workspaceBindings") { self.key = key }

    public func bindings(in scope: Scope) throws -> [Binding] {
        try entries().filter { $0.scope == scope }
    }

    /// Call only after the owner API verified this exact workspace and logical machine.
    @discardableResult
    public func remember(workspace: String, machine: String, scope: Scope, target: String? = nil) throws -> Bool {
        var all = try entries()
        let existing = all.firstIndex(where: { $0.scope == scope && $0.workspace == workspace && $0.machine == machine })
        if let index = existing {
            if let target { all[index].targets.insert(target) }
        } else {
            all.removeAll { $0.scope == scope && ($0.workspace == workspace || $0.machine == machine) }
            all.append(Binding(scope: scope, workspace: workspace, machine: machine, targets: Set([machine] + (target.map { [$0] } ?? []))))
        }
        if let defaults = defaults() { defaults.set(try JSONEncoder().encode(all), forKey: key) }
        else { memory = all }
        return existing == nil
    }

    /// An uncertain owner read leaves the previous list intact. A carrier omission alone is
    /// never allowed to remove a workspace whose replacement lives in the platform registry.
    public func project(_ rows: [CloudMachine], scope: Scope?, owner: CloudTurnRewindClient,
                        isCurrent: @MainActor (Scope) -> Bool) async throws -> [CloudMachine] {
        guard let scope, isCurrent(scope) else { throw CancellationError() }
        var projections: [CloudWorkspaceProjection] = []
        for binding in try bindings(in: scope) {
            projections.append(try await .read(binding: binding, machine: { try await owner.machine(workspace: $0) },
                                               connection: { try await owner.connection(workspace: $0) }))
        }
        guard isCurrent(scope), !Task.isCancelled else { throw CancellationError() }
        for projection in projections {
            if let target = projection.connection {
                try remember(workspace: projection.binding.workspace, machine: projection.binding.machine,
                             scope: scope, target: target.connectionMachine)
            }
        }
        return CloudWorkspaceProjection.applying(projections, to: rows)
    }

    /// Resolve every connect afresh; persisted targets suppress stale rows but never authorize
    /// opening a carrier after the owner has rewound again on another device.
    public func connection(machine: String, scope: Scope?, owner: CloudTurnRewindClient,
                           isCurrent: @MainActor (Scope) -> Bool) async throws -> CloudWorkspaceConnection? {
        guard let scope, isCurrent(scope) else { throw CancellationError() }
        guard let binding = try bindings(in: scope).first(where: { $0.machine == machine }) else { return nil }
        let data = try await owner.connection(workspace: binding.workspace)
        let target = try JSONDecoder().decode(CloudWorkspaceConnection.self, from: data).checked(machine: machine)
        guard isCurrent(scope), !Task.isCancelled else { throw CancellationError() }
        try remember(workspace: binding.workspace, machine: machine, scope: scope, target: target.connectionMachine)
        return target
    }

    private func entries() throws -> [Binding] {
        guard let defaults = defaults() else { return memory }
        guard let data = defaults.data(forKey: key) else { return [] }
        // Corrupt metadata must fail closed, not quietly reconnect to a retired source VM.
        return try JSONDecoder().decode([Binding].self, from: data)
    }
}

/// An owner-authenticated carrier descriptor. Raw provider VM ids are never dialable app links.
public struct CloudWorkspaceConnection: Decodable, Sendable, Equatable {
    public let machineId: String
    public let generation: Int
    public let provider: String
    public let connectionMachine: String

    public func checked(machine: String) throws -> Self {
        guard machineId == machine, generation >= 0,
              provider == "freestyle" || provider == "freestyle-vm-api" || provider == "freestyle-cloud",
              connectionMachine.utf8.count == 23,
              connectionMachine.range(of: #"^vm_[a-z0-9]{20}$"#, options: .regularExpression) != nil
        else { throw CloudTurnRewindClient.Failure.invalidReply }
        return self
    }
}

/// Adapts authoritative platform records into the native machine list. CloudDO supplies carrier
/// metadata; the workspace API supplies identity and lifecycle. No provider handle becomes identity.
public struct CloudWorkspaceProjection: Sendable {
    public struct Record: Decodable, Sendable {
        public struct Machine: Decodable, Sendable {
            public let id: String
            public let provider: String
            public let state: String
            public let creator: String
            public let createdAt: Double
        }
        public let workspace: String
        public let machine: Machine
    }

    public let binding: CloudWorkspaceBindings.Binding
    public let record: Record?
    public let connection: CloudWorkspaceConnection?

    public static func read(binding: CloudWorkspaceBindings.Binding,
                            machine: @Sendable (String) async throws -> Data,
                            connection: @Sendable (String) async throws -> Data) async throws -> Self {
        let data: Data
        do { data = try await machine(binding.workspace) }
        catch CloudTurnRewindClient.Failure.http(404) {
            return Self(binding: binding, record: nil, connection: nil)
        }
        let record = try JSONDecoder().decode(Record.self, from: data)
        guard record.workspace == binding.workspace, record.machine.id == binding.machine else {
            throw CloudTurnRewindClient.Failure.invalidReply
        }
        if record.machine.state == "gone" { return Self(binding: binding, record: nil, connection: nil) }
        let target = try JSONDecoder().decode(CloudWorkspaceConnection.self, from: await connection(binding.workspace))
            .checked(machine: binding.machine)
        return Self(binding: binding, record: record, connection: target)
    }

    public static func applying(_ projections: [Self], to rows: [CloudMachine]) -> [CloudMachine] {
        let hidden = projections.reduce(into: Set<String>()) { ids, projection in
            ids.formUnion(projection.binding.targets)
            ids.insert(projection.binding.machine)
            if let target = projection.connection { ids.insert(target.connectionMachine) }
        }
        return rows.filter { !hidden.contains($0.id) } + projections.compactMap { projection in
            guard let record = projection.record, let target = projection.connection else { return nil }
            var row = rows.first { $0.id == target.connectionMachine }
                ?? rows.first { $0.id == record.machine.id }
                ?? CloudMachine(id: record.machine.id)
            row.id = record.machine.id
            row.provider = record.machine.provider
            row.createdBy = record.machine.creator
            row.createdAt = Date(timeIntervalSince1970: record.machine.createdAt / 1000)
            row.status = switch record.machine.state {
            case "running": .running
            case "starting", "waking": .starting
            case "paused", "stopped": .paused
            case "failed": .failed
            default: .unknown
            }
            return row
        }
    }
}
