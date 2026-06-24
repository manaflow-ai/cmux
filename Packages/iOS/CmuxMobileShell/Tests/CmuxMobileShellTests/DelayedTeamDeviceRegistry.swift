import CMUXMobileCore
import CmuxMobileShell
import CmuxMobileShellModel

actor DelayedTeamDeviceRegistry: DeviceRegistryRefreshing {
    private let teamIDProvider: @Sendable () async -> String?
    private let devicesByTeam: [String: [RegistryDevice]]
    private let blockedTeams: Set<String>
    private var startedTeams: Set<String> = []
    private var startWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    private var blockers: [String: CheckedContinuation<Void, Never>] = [:]

    init(
        teamIDProvider: @escaping @Sendable () async -> String?,
        devicesByTeam: [String: [RegistryDevice]],
        blockedTeams: Set<String>
    ) {
        self.teamIDProvider = teamIDProvider
        self.devicesByTeam = devicesByTeam
        self.blockedTeams = blockedTeams
    }

    func freshRoutes(forMacDeviceID macDeviceID: String) async -> [CmxAttachRoute]? { nil }

    func listDevices() async -> DeviceRegistryListOutcome {
        let key = await teamIDProvider() ?? ""
        markStarted(key)
        if blockedTeams.contains(key) {
            await withCheckedContinuation { continuation in
                blockers[key] = continuation
            }
        }
        return .ok(devicesByTeam[key] ?? [])
    }

    func waitUntilLoadStarted(teamID: String?) async {
        let key = teamID ?? ""
        if startedTeams.contains(key) { return }
        await withCheckedContinuation { continuation in
            startWaiters[key, default: []].append(continuation)
        }
    }

    func release(teamID: String?) {
        let key = teamID ?? ""
        blockers.removeValue(forKey: key)?.resume()
    }

    private func markStarted(_ key: String) {
        startedTeams.insert(key)
        let waiters = startWaiters.removeValue(forKey: key) ?? []
        for waiter in waiters { waiter.resume() }
    }
}
