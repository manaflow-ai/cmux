import Darwin
import Foundation

struct SidebarAgentTitleRegistration: Equatable, Sendable {
    let statusKey: String
    let processNameNeedles: [String]
}

struct SidebarAgentPIDProbeRequest: Sendable {
    let workspaceId: UUID
    let key: String
    let pid: pid_t
}

struct SidebarAgentPIDProbeResult: Sendable {
    let workspaceId: UUID
    let key: String
    let state: SidebarAgentProcessState
}

struct SidebarAgentPanelTitleUpdateKey: Hashable {
    let tabId: UUID
    let panelId: UUID
}

struct SidebarAgentPendingPanelTitleUpdate {
    var title: String
    var sawAgentTitleRegistration: Bool
}

final class SidebarAgentStatusTracking {
    private(set) var pendingPanelTitleUpdates: [SidebarAgentPanelTitleUpdateKey: SidebarAgentPendingPanelTitleUpdate] = [:]
    private(set) var panelAgentTitleRegistrations: [SidebarAgentPanelTitleUpdateKey: SidebarAgentTitleRegistration] = [:]
    private(set) var panelAgentTitleRegistrationSeenAt: [SidebarAgentPanelTitleUpdateKey: Date] = [:]
    private(set) var agentPIDProbeInFlight = false
    private(set) var agentPIDDiscoveryInFlight = false
    private(set) var agentPIDProbeGeneration: UInt64 = 0
    private var agentPIDProbeInFlightGeneration: UInt64?
    private var agentPIDDiscoveryInFlightGeneration: UInt64?
    private var agentPIDDiscoveryLastStartedAtByRegistration: [String: Date] = [:]

    func pendingPanelTitleUpdate(for key: SidebarAgentPanelTitleUpdateKey) -> SidebarAgentPendingPanelTitleUpdate? {
        pendingPanelTitleUpdates[key]
    }

    func setPendingPanelTitleUpdate(
        _ update: SidebarAgentPendingPanelTitleUpdate,
        for key: SidebarAgentPanelTitleUpdateKey
    ) {
        pendingPanelTitleUpdates[key] = update
    }

    func drainPendingPanelTitleUpdates() -> [SidebarAgentPanelTitleUpdateKey: SidebarAgentPendingPanelTitleUpdate] {
        let updates = pendingPanelTitleUpdates
        pendingPanelTitleUpdates.removeAll(keepingCapacity: true)
        return updates
    }

    func clearPendingPanelTitleUpdates(workspaceId: UUID? = nil) {
        if let workspaceId {
            for key in Array(pendingPanelTitleUpdates.keys) where key.tabId == workspaceId {
                pendingPanelTitleUpdates.removeValue(forKey: key)
            }
        } else {
            pendingPanelTitleUpdates.removeAll()
        }
    }

    func panelAgentTitleRegistration(for key: SidebarAgentPanelTitleUpdateKey) -> SidebarAgentTitleRegistration? {
        panelAgentTitleRegistrations[key]
    }

    func setPanelAgentTitleRegistration(
        _ registration: SidebarAgentTitleRegistration,
        for key: SidebarAgentPanelTitleUpdateKey,
        seenAt: Date
    ) {
        panelAgentTitleRegistrations[key] = registration
        panelAgentTitleRegistrationSeenAt[key] = seenAt
    }

    func removePanelAgentTitleRegistration(for key: SidebarAgentPanelTitleUpdateKey) -> SidebarAgentTitleRegistration? {
        panelAgentTitleRegistrationSeenAt.removeValue(forKey: key)
        return panelAgentTitleRegistrations.removeValue(forKey: key)
    }

    func panelAgentTitleRegistrationSeenAt(for key: SidebarAgentPanelTitleUpdateKey) -> Date? {
        panelAgentTitleRegistrationSeenAt[key]
    }

    func panelAgentTitleRegistrationKeys(workspaceId: UUID? = nil) -> [SidebarAgentPanelTitleUpdateKey] {
        Array(panelAgentTitleRegistrations.keys).filter { key in
            workspaceId.map { key.tabId == $0 } ?? true
        }
    }

    func panelAgentTitleRegistrationSeenAtKeys() -> [SidebarAgentPanelTitleUpdateKey] {
        Array(panelAgentTitleRegistrationSeenAt.keys)
    }

    func discoveryStartedAt(for registrationKey: String) -> Date? {
        agentPIDDiscoveryLastStartedAtByRegistration[registrationKey]
    }

    func setDiscoveryStartedAt(_ date: Date, for registrationKey: String) {
        agentPIDDiscoveryLastStartedAtByRegistration[registrationKey] = date
    }

    func removeDiscoveryStartedAt(for registrationKey: String) {
        agentPIDDiscoveryLastStartedAtByRegistration.removeValue(forKey: registrationKey)
    }

    func clearDiscoveryStartedAt(workspaceId: UUID? = nil) {
        if let workspaceId {
            let prefix = "\(workspaceId.uuidString):"
            for registrationKey in Array(agentPIDDiscoveryLastStartedAtByRegistration.keys)
            where registrationKey.hasPrefix(prefix) {
                agentPIDDiscoveryLastStartedAtByRegistration.removeValue(forKey: registrationKey)
            }
        } else {
            agentPIDDiscoveryLastStartedAtByRegistration.removeAll()
        }
    }

    func beginAgentPIDProbe() -> UInt64? {
        guard !agentPIDProbeInFlight else { return nil }
        agentPIDProbeInFlight = true
        let generation = agentPIDProbeGeneration
        agentPIDProbeInFlightGeneration = generation
        return generation
    }

    func finishAgentPIDProbe(generation: UInt64) -> Bool {
        guard agentPIDProbeInFlightGeneration == generation else { return false }
        agentPIDProbeInFlight = false
        agentPIDProbeInFlightGeneration = nil
        return agentPIDProbeGeneration == generation
    }

    func beginAgentPIDDiscovery() -> UInt64? {
        guard !agentPIDDiscoveryInFlight else { return nil }
        agentPIDDiscoveryInFlight = true
        let generation = agentPIDProbeGeneration
        agentPIDDiscoveryInFlightGeneration = generation
        return generation
    }

    func finishAgentPIDDiscovery(generation: UInt64) -> Bool {
        guard agentPIDDiscoveryInFlightGeneration == generation else { return false }
        agentPIDDiscoveryInFlight = false
        agentPIDDiscoveryInFlightGeneration = nil
        return agentPIDProbeGeneration == generation
    }

    func reset() {
        pendingPanelTitleUpdates.removeAll()
        panelAgentTitleRegistrations.removeAll()
        panelAgentTitleRegistrationSeenAt.removeAll()
        agentPIDProbeGeneration &+= 1
        agentPIDProbeInFlight = false
        agentPIDDiscoveryInFlight = false
        agentPIDProbeInFlightGeneration = nil
        agentPIDDiscoveryInFlightGeneration = nil
        agentPIDDiscoveryLastStartedAtByRegistration.removeAll()
    }
}

enum SidebarAgentStatusService {
    static func titleRegistration(for title: String) -> SidebarAgentTitleRegistration? {
        let normalized = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return nil }

        if normalized.hasPrefix("codex-") {
            return SidebarAgentTitleRegistration(
                statusKey: "codex",
                processNameNeedles: ["codex", "node"]
            )
        }

        return nil
    }

    static func probeResults(for requests: [SidebarAgentPIDProbeRequest]) -> [SidebarAgentPIDProbeResult] {
        requests.map { request in
            SidebarAgentPIDProbeResult(
                workspaceId: request.workspaceId,
                key: request.key,
                state: SidebarAgentProcessProbe.processState(for: request.pid)
            )
        }
    }

    static func runtimeKey(for registration: SidebarAgentTitleRegistration, panelId: UUID) -> String {
        "\(registration.statusKey).\(panelId.uuidString.lowercased())"
    }

    static func registrationDeduplicationKey(workspaceId: UUID, panelId: UUID, statusKey: String) -> String {
        "\(workspaceId.uuidString):\(panelId.uuidString):\(statusKey)"
    }

    static func matchedPID(
        for registration: SidebarAgentTitleRegistration,
        rootPIDs: Set<Int>,
        processSnapshot: CmuxTopProcessSnapshot
    ) -> pid_t? {
        guard !rootPIDs.isEmpty else { return nil }

        let matchedPID = processSnapshot.expandedPIDs(rootPIDs: rootPIDs)
            .compactMap { pid -> (pid: Int, info: CmuxTopProcessInfo)? in
                guard let info = processSnapshot.processInfo(for: pid) else { return nil }
                return (pid, info)
            }
            .filter { candidate in
                let haystack = ([candidate.info.name, candidate.info.path].compactMap { $0 })
                    .joined(separator: " ")
                    .lowercased()
                return registration.processNameNeedles.contains { haystack.contains($0) }
            }
            .sorted { lhs, rhs in
                let lhsParentIsRoot = rootPIDs.contains(lhs.info.parentPID)
                let rhsParentIsRoot = rootPIDs.contains(rhs.info.parentPID)
                if lhsParentIsRoot != rhsParentIsRoot {
                    return lhsParentIsRoot
                }
                if lhs.info.parentPID != rhs.info.parentPID {
                    return lhs.info.parentPID < rhs.info.parentPID
                }
                return lhs.pid < rhs.pid
            }
            .first?
            .pid

        guard let matchedPID, matchedPID > 0 else { return nil }
        return pid_t(matchedPID)
    }
}

extension TabManager {
    func scheduleAgentPIDProbePass() {
        guard !agentStatusTracking.agentPIDProbeInFlight else { return }
        let requests = collectAgentPIDProbeRequests()
        scheduleAgentPIDDiscoveryFromTerminalTitlesIfNeeded()
        guard !requests.isEmpty else {
            applyAgentPIDProbeResults([])
            return
        }

        guard let generation = agentStatusTracking.beginAgentPIDProbe() else { return }
        Task.detached(priority: .utility) { [requests] in
            let results = SidebarAgentStatusService.probeResults(for: requests)
            await MainActor.run { [weak self] in
                guard let self,
                      self.agentStatusTracking.finishAgentPIDProbe(generation: generation) else { return }
                self.applyAgentPIDProbeResults(results)
            }
        }
    }

    func collectAgentPIDProbeRequests() -> [SidebarAgentPIDProbeRequest] {
        tabs.flatMap { tab in
            tab.agentPIDs.compactMap { key, pid in
                guard pid > 0 else { return nil }
                return SidebarAgentPIDProbeRequest(workspaceId: tab.id, key: key, pid: pid)
            }
        }
    }

    func applyAgentPIDProbeResults(_ results: [SidebarAgentPIDProbeResult]) {
        let tabsById = Dictionary(uniqueKeysWithValues: tabs.map { ($0.id, $0) })
        for result in results {
            guard let tab = tabsById[result.workspaceId],
                  tab.agentPIDs[result.key] == result.state.pid else {
                continue
            }
            tab.updateAgentProcessState(key: result.key, state: result.state)
        }

        for tab in tabs {
            var keysToRemove: Set<String> = []
            for (key, pid) in tab.agentPIDs {
                guard pid > 0 else {
                    keysToRemove.insert(key)
                    continue
                }
                if let state = tab.agentProcessStates[key],
                   state.pid == pid,
                   !state.isAlive {
                    keysToRemove.insert(key)
                }
            }
            for key in Array(tab.agentProcessStates.keys) where tab.agentPIDs[key] == nil {
                keysToRemove.insert(key)
            }
            if !keysToRemove.isEmpty {
                for key in keysToRemove.sorted() {
                    tab.clearAgentPID(key: key, clearStatus: true, refreshPorts: false)
                }
                tab.refreshTrackedAgentPorts()
            }
        }
    }

    func agentTitleRegistrationCandidates() -> [(Workspace, UUID, SidebarAgentTitleRegistration)] {
        pruneExpiredPanelAgentTitleRegistrations()
        return tabs.flatMap { tab in
            tab.panels.keys.compactMap { panelId -> (Workspace, UUID, SidebarAgentTitleRegistration)? in
                let key = SidebarAgentPanelTitleUpdateKey(tabId: tab.id, panelId: panelId)
                guard let registration = agentStatusTracking.panelAgentTitleRegistration(for: key) else {
                    return nil
                }
                let runtimeKey = SidebarAgentStatusService.runtimeKey(
                    for: registration,
                    panelId: panelId
                )
                guard tab.agentPIDs[runtimeKey] == nil else {
                    return nil
                }
                return (tab, panelId, registration)
            }
        }
    }

    func scheduleAgentPIDDiscoveryFromTerminalTitlesIfNeeded() {
        guard !agentStatusTracking.agentPIDDiscoveryInFlight else {
            return
        }
        let now = Date()
        let dueRegistrationKeys = Set(
            agentTitleRegistrationCandidates().compactMap { tab, panelId, registration -> String? in
                let registrationKey = SidebarAgentStatusService.registrationDeduplicationKey(
                    workspaceId: tab.id,
                    panelId: panelId,
                    statusKey: registration.statusKey
                )
                if let lastStarted = agentStatusTracking.discoveryStartedAt(for: registrationKey),
                   now.timeIntervalSince(lastStarted) < Self.agentPIDDiscoveryMinimumInterval {
                    return nil
                }
                return registrationKey
            }
        )
        guard !dueRegistrationKeys.isEmpty else {
            return
        }

        guard let generation = agentStatusTracking.beginAgentPIDDiscovery() else { return }
        Task.detached(priority: .utility) { [dueRegistrationKeys] in
            let processSnapshot = CmuxTopProcessSnapshot.capture(includeProcessDetails: true)
            await MainActor.run { [weak self] in
                guard let self,
                      self.agentStatusTracking.finishAgentPIDDiscovery(generation: generation) else { return }
                let registeredKeys = self.registerAgentPIDsFromTerminalTitlesIfNeeded(
                    processSnapshot: processSnapshot,
                    allowedRegistrationKeys: dueRegistrationKeys
                )
                let completedAt = Date()
                for registrationKey in registeredKeys {
                    self.agentStatusTracking.setDiscoveryStartedAt(completedAt, for: registrationKey)
                }
            }
        }
    }

    func registerAgentPIDsFromTerminalTitlesIfNeeded(
        processSnapshot: CmuxTopProcessSnapshot,
        allowedRegistrationKeys: Set<String>? = nil
    ) -> Set<String> {
        let titleCandidates = agentTitleRegistrationCandidates()
            .sorted { lhs, rhs in
                if lhs.0.id != rhs.0.id {
                    return lhs.0.id.uuidString < rhs.0.id.uuidString
                }
                if lhs.1 != rhs.1 {
                    return lhs.1.uuidString < rhs.1.uuidString
                }
                return lhs.2.statusKey < rhs.2.statusKey
            }
        guard !titleCandidates.isEmpty else { return [] }

        var registeredKeys: Set<String> = []
        for (tab, panelId, registration) in titleCandidates {
            let registrationKey = SidebarAgentStatusService.registrationDeduplicationKey(
                workspaceId: tab.id,
                panelId: panelId,
                statusKey: registration.statusKey
            )
            if let allowedRegistrationKeys,
               !allowedRegistrationKeys.contains(registrationKey) {
                continue
            }
            let runtimeKey = SidebarAgentStatusService.runtimeKey(
                for: registration,
                panelId: panelId
            )
            guard !registeredKeys.contains(registrationKey),
                  tab.agentPIDs[runtimeKey] == nil else {
                continue
            }
            if registerAgentPID(registration, workspace: tab, panelId: panelId, processSnapshot: processSnapshot) {
                registeredKeys.insert(registrationKey)
            }
        }
        return registeredKeys
    }

    func pruneExpiredPanelAgentTitleRegistrations(now: Date = Date()) {
        for key in agentStatusTracking.panelAgentTitleRegistrationSeenAtKeys() {
            guard let seenAt = agentStatusTracking.panelAgentTitleRegistrationSeenAt(for: key) else { continue }
            if now.timeIntervalSince(seenAt) > Self.panelAgentTitleRegistrationLifetime {
                clearPanelAgentTitleRegistration(for: key)
            }
        }
    }

    func clearPanelAgentTitleRegistration(for key: SidebarAgentPanelTitleUpdateKey) {
        if let registration = agentStatusTracking.removePanelAgentTitleRegistration(for: key) {
            let registrationKey = SidebarAgentStatusService.registrationDeduplicationKey(
                workspaceId: key.tabId,
                panelId: key.panelId,
                statusKey: registration.statusKey
            )
            agentStatusTracking.removeDiscoveryStartedAt(for: registrationKey)
        }
    }

    func clearPanelTitleTracking(workspaceId: UUID) {
        agentStatusTracking.clearPendingPanelTitleUpdates(workspaceId: workspaceId)
        for key in agentStatusTracking.panelAgentTitleRegistrationKeys(workspaceId: workspaceId) {
            clearPanelAgentTitleRegistration(for: key)
        }
        agentStatusTracking.clearDiscoveryStartedAt(workspaceId: workspaceId)
    }

    func registerAgentPID(
        _ registration: SidebarAgentTitleRegistration,
        workspace: Workspace,
        panelId: UUID,
        processSnapshot: CmuxTopProcessSnapshot
    ) -> Bool {
        var rootPIDs = processSnapshot.pids(forCMUXSurfaceID: panelId)
        if let ttyName = workspace.surfaceTTYNames[panelId] {
            rootPIDs.formUnion(processSnapshot.pids(forTTYName: ttyName))
        }
        guard !rootPIDs.isEmpty else { return false }

        guard let matchedPID = SidebarAgentStatusService.matchedPID(
            for: registration,
            rootPIDs: rootPIDs,
            processSnapshot: processSnapshot
        ) else {
            return false
        }
        let runtimeKey = SidebarAgentStatusService.runtimeKey(for: registration, panelId: panelId)
        clearPanelAgentTitleRegistration(for: SidebarAgentPanelTitleUpdateKey(tabId: workspace.id, panelId: panelId))
        workspace.setAgentPID(key: runtimeKey, panelId: panelId, pid: matchedPID)
        return true
    }

    func flushPendingPanelTitleUpdates() {
        guard !agentStatusTracking.pendingPanelTitleUpdates.isEmpty else { return }
        let updates = agentStatusTracking.drainPendingPanelTitleUpdates()
        let shouldDiscoverAgentPID = updates.contains { key, update in
            update.sawAgentTitleRegistration || agentStatusTracking.panelAgentTitleRegistration(for: key) != nil
        }
        for (key, update) in updates {
            updatePanelTitle(tabId: key.tabId, panelId: key.panelId, title: update.title)
        }
        if shouldDiscoverAgentPID {
            scheduleAgentPIDDiscoveryFromTerminalTitlesIfNeeded()
        }
    }

    func updatePanelTitle(tabId: UUID, panelId: UUID, title: String) {
        guard let tab = tabs.first(where: { $0.id == tabId }) else { return }
        let didChange = tab.updatePanelTitle(panelId: panelId, title: title)
        guard didChange else { return }

        if tab.focusedPanelId == panelId {
            tab.applyProcessTitle(title)
            if selectedTabId == tabId {
                updateWindowTitle(for: tab)
            }
        }
    }
}
