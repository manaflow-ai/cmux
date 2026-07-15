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
    private var loadAllCount = 0
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
        instanceTag: String? = nil,
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
            recordsByTeam[key]?[index].instanceTag = instanceTag
            recordsByTeam[key]?[index].lastSeenAt = now
            recordsByTeam[key]?[index].isActive = markActive
        } else {
            recordsByTeam[key, default: []].append(MobilePairedMac(
                macDeviceID: macDeviceID,
                displayName: displayName,
                routes: routes,
                createdAt: now,
                lastSeenAt: now,
                isActive: markActive,
                stackUserID: stackUserID,
                teamID: teamID,
                instanceTag: instanceTag
            ))
        }
        upsertCount += 1
        resumeUpsertWaiters()
    }

    @discardableResult
    func upsertRoutesIfAuthorized(
        macDeviceID: String,
        displayName: String?,
        routes: [CmxAttachRoute],
        condition: MobilePairedMacRouteWriteCondition,
        markActive: Bool?,
        stackUserID: String?,
        teamID: String?,
        now: Date
    ) async throws -> Bool {
        if gatedUpsertIDs.contains(macDeviceID) {
            markUpsertStarted(macDeviceID)
            await withCheckedContinuation { continuation in
                upsertBlockers[macDeviceID] = continuation
            }
        }
        let key = teamID ?? ""
        let targetKey = recordsByTeam[key]?.contains { $0.macDeviceID == macDeviceID } == true
            ? key
            : (key.isEmpty ? key : "")
        let index = recordsByTeam[targetKey]?.firstIndex { $0.macDeviceID == macDeviceID }
        switch condition {
        case .matchingInstanceTag(let expectedInstanceTag):
            guard let index,
                  recordsByTeam[targetKey]?[index].instanceTag == expectedInstanceTag else { return false }
        case .unclaimed:
            guard index.flatMap({ recordsByTeam[targetKey]?[$0].instanceTag }) == nil else { return false }
        }
        if markActive == true {
            for visibleKey in Set([key, key.isEmpty ? key : ""]) {
                recordsByTeam[visibleKey] = recordsByTeam[visibleKey]?.map { mac in
                    var copy = mac
                    copy.isActive = false
                    return copy
                }
            }
        }
        if let index {
            recordsByTeam[targetKey]?[index].displayName = displayName
            recordsByTeam[targetKey]?[index].routes = routes
            recordsByTeam[targetKey]?[index].lastSeenAt = now
            if let markActive { recordsByTeam[targetKey]?[index].isActive = markActive }
        } else {
            recordsByTeam[key, default: []].append(MobilePairedMac(
                macDeviceID: macDeviceID,
                displayName: displayName,
                routes: routes,
                createdAt: now,
                lastSeenAt: now,
                isActive: markActive ?? false,
                stackUserID: stackUserID,
                teamID: teamID
            ))
        }
        upsertCount += 1
        resumeUpsertWaiters()
        return true
    }

    func loadAll(stackUserID: String?, teamID: String?) async throws -> [MobilePairedMac] {
        loadAllCount += 1
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
    func setActive(macDeviceID: String, stackUserID: String?, teamID: String?) async throws {
        let key = teamID ?? ""
        recordsByTeam[key] = recordsByTeam[key]?.map { mac in
            var copy = mac
            copy.isActive = copy.macDeviceID == macDeviceID
            return copy
        }
    }
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

    func resetLoadAllCount() {
        loadAllCount = 0
    }

    func currentLoadAllCount() -> Int {
        loadAllCount
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
