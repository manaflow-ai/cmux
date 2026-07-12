import Darwin
import Foundation

private nonisolated struct TerminalResolverProcessIdentity: Sendable {
    let ttyDevice: Int64?
    let workspaceID: UUID?
    let surfaceID: UUID?
}

private nonisolated struct LiveTerminalResolverBinding: Sendable {
    let workspaceID: UUID
    let surfaceID: UUID
    let ttyName: String
    let ttyDevice: Int64?

    var payload: [String: Any] {
        [
            "workspace_id": workspaceID.uuidString,
            "surface_id": surfaceID.uuidString,
        ]
    }
}

private nonisolated struct TerminalResolverBindingCacheEntry: Sendable {
    let capturedAt: Date
    let bindings: [LiveTerminalResolverBinding]
}

private nonisolated struct TerminalResolverBindingCacheState {
    var entries: [ObjectIdentifier: TerminalResolverBindingCacheEntry] = [:]
    var generations: [ObjectIdentifier: UInt64] = [:]
    var refreshes: [ObjectIdentifier: UInt64] = [:]
}

private nonisolated enum TerminalResolverBindingCacheLookup {
    case cached([LiveTerminalResolverBinding])
    case refresh(generation: UInt64)
    case wait
}

private nonisolated final class TerminalResolverBindingCache: @unchecked Sendable {
    private let condition = NSCondition()
    private var state = TerminalResolverBindingCacheState()

    func lookup(
        key: ObjectIdentifier,
        now: Date,
        maximumAge: TimeInterval
    ) -> TerminalResolverBindingCacheLookup {
        condition.lock()
        defer { condition.unlock() }
        if let entry = state.entries[key],
           now.timeIntervalSince(entry.capturedAt) <= maximumAge {
            return .cached(entry.bindings)
        }
        if state.refreshes[key] != nil {
            return .wait
        }
        let generation = state.generations[key, default: 0]
        state.refreshes[key] = generation
        return .refresh(generation: generation)
    }

    func waitForRefresh(key: ObjectIdentifier) {
        condition.lock()
        while state.refreshes[key] != nil {
            condition.wait()
        }
        condition.unlock()
    }

    func completeRefresh(
        key: ObjectIdentifier,
        generation: UInt64,
        capturedAt: Date,
        bindings: [LiveTerminalResolverBinding]
    ) {
        condition.lock()
        defer {
            condition.broadcast()
            condition.unlock()
        }
        guard state.refreshes[key] == generation else { return }
        state.refreshes.removeValue(forKey: key)
        guard state.generations[key, default: 0] == generation else {
            state.generations.removeValue(forKey: key)
            return
        }
        if state.entries.count >= 8,
           let oldestKey = state.entries.min(by: {
               $0.value.capturedAt < $1.value.capturedAt
           })?.key {
            state.entries.removeValue(forKey: oldestKey)
            if state.refreshes[oldestKey] == nil {
                state.generations.removeValue(forKey: oldestKey)
            }
        }
        state.entries[key] = TerminalResolverBindingCacheEntry(
            capturedAt: capturedAt,
            bindings: bindings
        )
    }

    func invalidateAll() {
        condition.lock()
        state.entries.removeAll(keepingCapacity: true)
        state.generations = state.refreshes.reduce(into: [:]) { generations, refresh in
            generations[refresh.key] = refresh.value &+ 1
        }
        condition.unlock()
    }
}

private nonisolated let terminalResolverBindingCache = TerminalResolverBindingCache()

extension TerminalController {
    /// Resolves one hook caller without constructing `debug.terminals` or a
    /// `system.top` process tree. UI terminal bindings are shared for two
    /// seconds across hook storms and invalidated when TTY ownership changes.
    /// Requested PID identity is captured fresh because process creation and
    /// PID reuse are correctness boundaries, not cacheable presentation state.
    nonisolated func v2SystemResolveTerminal(params: [String: Any]) -> V2CallResult {
        let ttyName = v2NonEmptyString(v2String(params, "tty_name")).map(Self.terminalResolverTTYName)
        let pid: Int?
        if params["pid"] != nil {
            guard let parsedPID = v2Int(params, "pid"), parsedPID > 0 else {
                return .err(code: "invalid_params", message: "pid must be a positive integer", data: nil)
            }
            pid = parsedPID
        } else {
            pid = nil
        }
        guard ttyName != nil || pid != nil else {
            return .err(code: "invalid_params", message: "tty_name or pid is required", data: nil)
        }

        let processIdentity: TerminalResolverProcessIdentity? = pid.flatMap { pid in
            Self.terminalResolverProcessIdentity(pid: pid)
        }
        let bindings = cachedLiveTerminalResolverBindings(maximumAge: 2)
        let ttyBindings = ttyName.map { requestedTTY in
            bindings.filter { $0.ttyName == requestedTTY }
        } ?? []
        let pidBinding = Self.pidTerminalResolverBinding(
            processIdentity,
            liveBindings: bindings
        )
        let pidBindingPayload: Any = if let pidBinding {
            pidBinding.payload
        } else {
            NSNull()
        }
        return .ok([
            "tty_bindings": ttyBindings.map(\.payload),
            "pid_binding": pidBindingPayload,
        ])
    }

    private nonisolated func cachedLiveTerminalResolverBindings(
        maximumAge: TimeInterval
    ) -> [LiveTerminalResolverBinding] {
        let cacheKey = ObjectIdentifier(self)
        while true {
            switch terminalResolverBindingCache.lookup(
                key: cacheKey,
                now: Date(),
                maximumAge: maximumAge
            ) {
            case .cached(let bindings):
                return bindings
            case .wait:
                terminalResolverBindingCache.waitForRefresh(key: cacheKey)
            case .refresh(let generation):
                let rawBindings = v2MainSync(commandKey: "system.resolve_terminal") {
                    self.liveTerminalResolverBindings()
                }
                var seen: Set<String> = []
                let captured = rawBindings.compactMap { binding -> LiveTerminalResolverBinding? in
                    let key = "\(binding.workspaceID.uuidString):\(binding.surfaceID.uuidString)"
                    guard seen.insert(key).inserted else { return nil }
                    return LiveTerminalResolverBinding(
                        workspaceID: binding.workspaceID,
                        surfaceID: binding.surfaceID,
                        ttyName: Self.terminalResolverTTYName(binding.ttyName),
                        ttyDevice: CmuxTopProcessSnapshot.deviceIdentifier(forTTYName: binding.ttyName)
                    )
                }.sorted {
                    if $0.workspaceID != $1.workspaceID {
                        return $0.workspaceID.uuidString < $1.workspaceID.uuidString
                    }
                    return $0.surfaceID.uuidString < $1.surfaceID.uuidString
                }
                terminalResolverBindingCache.completeRefresh(
                    key: cacheKey,
                    generation: generation,
                    capturedAt: Date(),
                    bindings: captured
                )
            }
        }
    }

    nonisolated static func invalidateTerminalResolverBindingCaches() {
        terminalResolverBindingCache.invalidateAll()
    }

    private nonisolated static func terminalResolverProcessIdentity(
        pid: Int
    ) -> TerminalResolverProcessIdentity? {
        guard pid > 0,
              pid <= Int(Int32.max),
              let initialIdentity = AgentPIDProcessIdentity(pid: pid_t(pid)) else {
            return nil
        }
        var currentPID = pid
        var visited: Set<Int> = []
        var ttyDevice: Int64?
        var workspaceID: UUID?
        var surfaceID: UUID?
        while currentPID > 0,
              visited.insert(currentPID).inserted,
              let process = terminalResolverBSDInfo(pid: currentPID) {
            let rawTTYDevice = Int64(process.e_tdev)
            if ttyDevice == nil, rawTTYDevice > 0 {
                ttyDevice = rawTTYDevice
            }
            if workspaceID == nil, surfaceID == nil,
               let processArguments = CmuxTopProcessSnapshot.processArgumentsAndEnvironment(for: currentPID),
               let scope = CmuxTopProcessSnapshot.cmuxScope(
                   arguments: processArguments.arguments,
                   environment: processArguments.environment
               ),
               let scopedWorkspaceID = scope.workspaceID,
               let scopedSurfaceID = scope.surfaceID {
                workspaceID = scopedWorkspaceID
                surfaceID = scopedSurfaceID
            }
            if ttyDevice != nil, workspaceID != nil, surfaceID != nil { break }
            currentPID = Int(process.pbi_ppid)
        }
        guard AgentPIDProcessIdentity(pid: pid_t(pid)) == initialIdentity else {
            return nil
        }
        return TerminalResolverProcessIdentity(
            ttyDevice: ttyDevice,
            workspaceID: workspaceID,
            surfaceID: surfaceID
        )
    }

    private nonisolated static func terminalResolverBSDInfo(pid: Int) -> proc_bsdinfo? {
        guard pid > 0, pid <= Int(Int32.max) else { return nil }
        var info = proc_bsdinfo()
        let expectedSize = MemoryLayout<proc_bsdinfo>.stride
        let size = proc_pidinfo(
            pid_t(pid),
            PROC_PIDTBSDINFO,
            0,
            &info,
            Int32(expectedSize)
        )
        return size == expectedSize ? info : nil
    }

    @MainActor
    private func liveTerminalResolverBindings() -> [LiveTerminalResolverBinding] {
        guard let app = AppDelegate.shared else { return [] }
        var bindings: [LiveTerminalResolverBinding] = []
        for summary in app.listMainWindowSummaries() {
            guard let manager = app.tabManagerFor(windowId: summary.windowId) else { continue }
            for workspace in manager.tabs {
                for (surfaceID, rawTTY) in workspace.surfaceTTYNames
                    where workspace.panels[surfaceID] != nil {
                    bindings.append(LiveTerminalResolverBinding(
                        workspaceID: workspace.id,
                        surfaceID: surfaceID,
                        ttyName: rawTTY,
                        ttyDevice: nil
                    ))
                }
            }
        }
        return bindings
    }

    private nonisolated static func terminalResolverTTYName(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.split(separator: "/").last.map(String.init) ?? trimmed
    }

    private nonisolated static func pidTerminalResolverBinding(
        _ identity: TerminalResolverProcessIdentity?,
        liveBindings: [LiveTerminalResolverBinding]
    ) -> LiveTerminalResolverBinding? {
        guard let identity else { return nil }
        let ttyMatches = identity.ttyDevice.map { device in
            liveBindings.filter { $0.ttyDevice == device }
        } ?? []
        let scoped = liveBindings.first {
            $0.workspaceID == identity.workspaceID && $0.surfaceID == identity.surfaceID
        }
        if ttyMatches.count == 1 {
            return ttyMatches[0]
        }
        if ttyMatches.count > 1, let scoped,
           ttyMatches.contains(where: {
               $0.workspaceID == scoped.workspaceID && $0.surfaceID == scoped.surfaceID
           }) {
            return scoped
        }
        return ttyMatches.isEmpty ? scoped : nil
    }
}
