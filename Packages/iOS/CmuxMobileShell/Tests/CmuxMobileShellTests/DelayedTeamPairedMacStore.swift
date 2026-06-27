import CMUXMobileCore
import CmuxMobilePairedMac
import Foundation

actor DelayedTeamPairedMacStore: MobilePairedMacStoring {
    private var recordsByTeam: [String: [MobilePairedMac]]
    private let blockedTeams: Set<String>
    private var startedTeams: Set<String> = []
    private var startWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    private var blockers: [String: CheckedContinuation<Void, Never>] = [:]
    private var upsertCount = 0
    private var upsertWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var gatedUpsertIDs: Set<String> = []
    private var upsertStartedIDs: Set<String> = []
    private var upsertStartWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    private var upsertBlockers: [String: CheckedContinuation<Void, Never>] = [:]
    private var removeFailures: Set<String> = []
    private var gatedRemoveFailures: Set<String> = []
    private var removeStartedIDs: Set<String> = []
    private var removeStartWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    private var removeBlockers: [String: CheckedContinuation<Void, Never>] = [:]

    init(recordsByTeam: [String: [MobilePairedMac]], blockedTeams: Set<String>) {
        self.recordsByTeam = recordsByTeam
        self.blockedTeams = blockedTeams
    }

    func upsert(
        macDeviceID: String,
        displayName: String?,
        routes: [CmxAttachRoute],
        attachToken: String?,
        attachTokenExpiresAt: Date?,
        markActive: Bool,
        stackUserID: String?,
        teamID: String?,
        now: Date
    ) async throws {
        if gatedUpsertIDs.contains(macDeviceID) {
            markUpsertStarted(macDeviceID)
            await withCheckedContinuation { continuation in
                upsertBlockers[macDeviceID] = continuation
            }
        }
        let key = teamID ?? ""
        if markActive {
            recordsByTeam[key] = recordsByTeam[key]?.map { mac in
                var copy = mac
                copy.isActive = false
                return copy
            }
        }
        if let index = recordsByTeam[key]?.firstIndex(where: { $0.macDeviceID == macDeviceID }) {
            recordsByTeam[key]?[index].displayName = displayName
            recordsByTeam[key]?[index].routes = routes
            if let attachToken {
                recordsByTeam[key]?[index].attachToken = attachToken
            }
            if let attachTokenExpiresAt {
                recordsByTeam[key]?[index].attachTokenExpiresAt = attachTokenExpiresAt
            }
            recordsByTeam[key]?[index].lastSeenAt = now
            recordsByTeam[key]?[index].isActive = markActive
        } else {
            recordsByTeam[key, default: []].append(MobilePairedMac(
                macDeviceID: macDeviceID,
                displayName: displayName,
                routes: routes,
                attachToken: attachToken,
                attachTokenExpiresAt: attachTokenExpiresAt,
                createdAt: now,
                lastSeenAt: now,
                isActive: markActive,
                stackUserID: stackUserID,
                teamID: teamID
            ))
        }
        upsertCount += 1
        resumeUpsertWaiters()
    }

    func updateRoutes(
        macDeviceID: String,
        displayName: String?,
        routes: [CmxAttachRoute],
        stackUserID: String?,
        teamID: String?,
        now: Date
    ) async throws {
        let key = teamID ?? ""
        guard let index = recordsByTeam[key]?.firstIndex(where: { $0.macDeviceID == macDeviceID }) else {
            return
        }
        recordsByTeam[key]?[index].displayName = displayName
        recordsByTeam[key]?[index].routes = routes
        recordsByTeam[key]?[index].lastSeenAt = now
        upsertCount += 1
        resumeUpsertWaiters()
    }

    func loadAll(stackUserID: String?, teamID: String?) async throws -> [MobilePairedMac] {
        let key = teamID ?? ""
        markStarted(key)
        if blockedTeams.contains(key) {
            await withCheckedContinuation { continuation in
                blockers[key] = continuation
            }
        }
        let scoped = recordsByTeam[key] ?? []
        guard key != "" else { return scoped }
        let legacyTeamless = (recordsByTeam[""] ?? []).filter { mac in
            mac.stackUserID == nil || mac.stackUserID == stackUserID
        }
        return scoped + legacyTeamless
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
    ) async throws {
        let key = teamID ?? ""
        guard let index = recordsByTeam[key]?.firstIndex(where: { $0.macDeviceID == macDeviceID }) else { return }
        recordsByTeam[key]?[index].customName = customName
        recordsByTeam[key]?[index].customColor = customColor
        recordsByTeam[key]?[index].customIcon = customIcon
    }
    func remove(macDeviceID: String, stackUserID: String?, teamID: String?) async throws {
        if gatedRemoveFailures.contains(macDeviceID) {
            markRemoveStarted(macDeviceID)
            await withCheckedContinuation { continuation in
                removeBlockers[macDeviceID] = continuation
            }
            throw CocoaError(.fileWriteUnknown)
        }
        if removeFailures.contains(macDeviceID) {
            throw CocoaError(.fileWriteUnknown)
        }
        let key = teamID ?? ""
        recordsByTeam[key]?.removeAll { $0.macDeviceID == macDeviceID }
    }
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

    func waitUntilUpsertCount(_ count: Int) async {
        if upsertCount >= count { return }
        await withCheckedContinuation { continuation in
            upsertWaiters.append((count, continuation))
        }
    }

    func currentUpsertCount() -> Int {
        upsertCount
    }

    func gateUpsert(macDeviceID: String) {
        gatedUpsertIDs.insert(macDeviceID)
    }

    func waitUntilUpsertStarted(macDeviceID: String) async {
        if upsertStartedIDs.contains(macDeviceID) { return }
        await withCheckedContinuation { continuation in
            upsertStartWaiters[macDeviceID, default: []].append(continuation)
        }
    }

    func releaseUpsert(macDeviceID: String) {
        upsertBlockers.removeValue(forKey: macDeviceID)?.resume()
    }

    func failRemove(macDeviceID: String) {
        removeFailures.insert(macDeviceID)
    }

    func failRemoveAfterRelease(macDeviceID: String) {
        gatedRemoveFailures.insert(macDeviceID)
    }

    func waitUntilRemoveStarted(macDeviceID: String) async {
        if removeStartedIDs.contains(macDeviceID) { return }
        await withCheckedContinuation { continuation in
            removeStartWaiters[macDeviceID, default: []].append(continuation)
        }
    }

    func releaseRemove(macDeviceID: String) {
        removeBlockers.removeValue(forKey: macDeviceID)?.resume()
    }

    private func markStarted(_ key: String) {
        startedTeams.insert(key)
        let waiters = startWaiters.removeValue(forKey: key) ?? []
        for waiter in waiters { waiter.resume() }
    }

    private func markUpsertStarted(_ macDeviceID: String) {
        upsertStartedIDs.insert(macDeviceID)
        let waiters = upsertStartWaiters.removeValue(forKey: macDeviceID) ?? []
        for waiter in waiters { waiter.resume() }
    }

    private func markRemoveStarted(_ macDeviceID: String) {
        removeStartedIDs.insert(macDeviceID)
        let waiters = removeStartWaiters.removeValue(forKey: macDeviceID) ?? []
        for waiter in waiters { waiter.resume() }
    }

    private func resumeUpsertWaiters() {
        let ready = upsertWaiters.filter { upsertCount >= $0.0 }
        upsertWaiters.removeAll { upsertCount >= $0.0 }
        for (_, waiter) in ready { waiter.resume() }
    }
}
