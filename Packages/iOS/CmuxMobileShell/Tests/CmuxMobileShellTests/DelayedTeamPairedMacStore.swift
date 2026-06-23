import CMUXMobileCore
import CmuxMobilePairedMac
import Foundation

actor DelayedTeamPairedMacStore: MobilePairedMacStoring {
    private let recordsByTeam: [String: [MobilePairedMac]]
    private let blockedTeams: Set<String>
    private var startedTeams: Set<String> = []
    private var startWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    private var blockers: [String: CheckedContinuation<Void, Never>] = [:]

    init(recordsByTeam: [String: [MobilePairedMac]], blockedTeams: Set<String>) {
        self.recordsByTeam = recordsByTeam
        self.blockedTeams = blockedTeams
    }

    func upsert(
        macDeviceID: String,
        displayName: String?,
        routes: [CmxAttachRoute],
        markActive: Bool,
        stackUserID: String?,
        teamID: String?,
        now: Date
    ) async throws {}

    func loadAll(stackUserID: String?, teamID: String?) async throws -> [MobilePairedMac] {
        let key = teamID ?? ""
        markStarted(key)
        if blockedTeams.contains(key) {
            await withCheckedContinuation { continuation in
                blockers[key] = continuation
            }
        }
        return recordsByTeam[key] ?? []
    }

    func activeMac(stackUserID: String?, teamID: String?) async throws -> MobilePairedMac? { nil }
    func setActive(macDeviceID: String, stackUserID: String?, teamID: String?) async throws {}
    func clearActive(stackUserID: String?, teamID: String?) async throws {}
    func setCustomization(
        macDeviceID: String,
        customName: String?,
        customColor: String?,
        customIcon: String?,
        stackUserID: String?,
        teamID: String?,
        now: Date
    ) async throws {}
    func remove(macDeviceID: String, stackUserID: String?, teamID: String?) async throws {}
    func removeAll() async throws {}

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
