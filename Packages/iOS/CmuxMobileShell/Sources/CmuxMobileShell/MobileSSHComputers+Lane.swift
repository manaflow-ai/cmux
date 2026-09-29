public import CmuxMobileSSH
public import Foundation

/// A computer whose cmux-tui daemon the phone reaches over a carrier other
/// than SSH: a paired cmux-next Mac, through an irx `daemon` lane the Mac
/// splices onto its daemon socket (plans/cmux-next/cloud-ios.md). Its rows
/// and terminals ride the same seams as an SSH computer's cmux-tui session
/// (raw bytes into the phone's own Ghostty, phone-owned geometry), so the
/// shell needs no second terminal pipeline.
public struct MobileSSHLaneComputer: Sendable {
    /// The computer's display name (the paired Mac's name).
    public var name: String
    /// Opens one new carrier to the daemon. Called for the first control
    /// connection and again after one drops.
    public var openCarrier: @MainActor @Sendable () async throws -> any CmuxTUICarrier

    public init(name: String, openCarrier: @escaping @MainActor @Sendable () async throws -> any CmuxTUICarrier) {
        self.name = name
        self.openCarrier = openCarrier
    }
}

extension MobileSSHComputers {
    /// Handshake deadline for a control connection over a lane. The lane is
    /// already admitted, so this bounds only the daemon's `identify`.
    static let laneHandshakeTimeout: Duration = .seconds(15)

    /// Registers (or renames) a lane computer and lists its workspaces. A
    /// computer already registered keeps its live connection.
    public func registerLaneComputer(id: UUID, name: String, openCarrier: @escaping @MainActor @Sendable () async throws -> any CmuxTUICarrier) {
        let isNew = laneComputers[id] == nil
        laneComputers[id] = MobileSSHLaneComputer(name: name, openCarrier: openCarrier)
        guard isNew else {
            publish(hostID: id)
            return
        }
        statusByHost[id] = .connecting
        publish(hostID: id)
        Task { await refreshLaneComputer(id: id) }
    }

    /// Drops a lane computer: closes its connection and removes its rows.
    public func removeLaneComputer(id: UUID) async {
        guard laneComputers.removeValue(forKey: id) != nil else { return }
        laneConnectTasks.removeValue(forKey: id)?.cancel()
        await closeConnection(hostID: id)
        workspacesByHost[id] = nil
        statusByHost[id] = nil
        sink?.sshRemoveWorkspaceState(computerID: MobileSSHIdentifier(computerOf: id).rawValue)
    }

    /// Connects (if needed) and relists a lane computer.
    public func refreshLaneComputer(id: UUID) async {
        guard laneComputers[id] != nil else { return }
        do {
            _ = try await provider(for: id)
            await refreshWorkspaces(hostID: id)
        } catch {
            fail(hostID: id, error)
        }
    }

    /// Computer ids whose rows the phone serves itself: saved SSH hosts and
    /// lane computers.
    public var locallyServedComputerIDs: Set<String> {
        Set(hosts.map { MobileSSHIdentifier(computerOf: $0.id).rawValue })
            .union(laneComputers.keys.map { MobileSSHIdentifier(computerOf: $0).rawValue })
    }

    /// Display names of ``locallyServedComputerIDs``.
    public var locallyServedComputerNames: [String: String] {
        var names: [String: String] = [:]
        for host in hosts { names[MobileSSHIdentifier(computerOf: host.id).rawValue] = host.name }
        for (id, computer) in laneComputers { names[MobileSSHIdentifier(computerOf: id).rawValue] = computer.name }
        return names
    }

    /// The name rows publish under: a saved host's, else a lane computer's.
    func displayName(hostID: UUID) -> String? {
        host(id: hostID)?.name ?? laneComputers[hostID]?.name
    }

    /// The lane computer's registry, opening its first control connection.
    /// Concurrent callers share one attempt.
    func laneProvider(for id: UUID) async throws -> MobileSSHHostProviders {
        if let registry = providers[id] { return registry }
        if let task = laneConnectTasks[id] { return try await task.value }
        guard let computer = laneComputers[id] else { throw MobileSSHRuntimeError.cmuxTUISessionGone }
        statusByHost[id] = .connecting
        publish(hostID: id)
        let open = computer.openCarrier
        let task = Task { @MainActor () throws -> MobileSSHHostProviders in
            try await MobileSSHHostProviders.daemonLane(
                connect: {
                    try await CmuxTUIControl.open(
                        carrier: try await open(),
                        session: nil,
                        clientName: "cmux-ios",
                        handshakeTimeout: Self.laneHandshakeTimeout
                    )
                },
                // A dropped control relists on the next use; the paired
                // Mac's connection owns reporting that the Mac is gone.
                isCarrierOpen: { false }
            )
        }
        laneConnectTasks[id] = task
        defer { laneConnectTasks[id] = nil }
        let registry = try await task.value
        // Removed (or re-registered and connected) while connecting.
        guard laneComputers[id] != nil, providers[id] == nil else {
            await registry.closeLane()
            if let existing = providers[id] { return existing }
            throw MobileSSHRuntimeError.cmuxTUISessionGone
        }
        registry.onTopologyChange = { [weak self] in
            Task { await self?.refreshWorkspaces(hostID: id) }
        }
        providers[id] = registry
        kindAvailabilityByHost[id] = registry.availability
        statusByHost[id] = .connected
        publish(hostID: id)
        return registry
    }
}
