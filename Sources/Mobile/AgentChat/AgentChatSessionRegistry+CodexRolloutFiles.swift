import Foundation

extension AgentChatSessionRegistry {
    func preferredCodexSessionIDBySurfaceID(
        onlySurfaceIDs: Set<UUID>?
    ) -> [String: String] {
        let requestedSurfaceIDs = onlySurfaceIDs.map { Set($0.map(\.uuidString)) }
        return codexHookBindingBySurfaceID.reduce(into: [:]) { result, element in
            guard requestedSurfaceIDs?.contains(element.key) ?? true else { return }
            result[element.key] = element.value.sessionID
        }
    }

    func rememberCodexHookBinding(
        sessionID: String,
        surfaceID: String,
        updatedAt: Date
    ) {
        if let current = codexHookBindingBySurfaceID[surfaceID] {
            guard updatedAt > current.updatedAt
                || (updatedAt == current.updatedAt && sessionID > current.sessionID) else {
                return
            }
        }
        codexHookBindingBySurfaceID[surfaceID] = (sessionID, updatedAt)
        if codexHookBindingBySurfaceID.count > Self.codexHookBindingCapacity,
           let oldest = codexHookBindingBySurfaceID.min(by: { left, right in
               if left.value.updatedAt != right.value.updatedAt {
                   return left.value.updatedAt < right.value.updatedAt
               }
               return left.key < right.key
           }) {
            codexHookBindingBySurfaceID.removeValue(forKey: oldest.key)
        }
    }

    /// libproc: the `~/.codex/sessions/**/rollout-*.jsonl` paths the process
    /// holds open (codex keeps its rollouts open for writing).
    nonisolated static func openCodexRolloutPaths(pid: Int) -> [String] {
        let listSize = proc_pidinfo(pid_t(pid), PROC_PIDLISTFDS, 0, nil, 0)
        guard listSize > 0 else { return [] }
        let count = Int(listSize) / MemoryLayout<proc_fdinfo>.stride
        guard count > 0 else { return [] }
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: count)
        let used = proc_pidinfo(pid_t(pid), PROC_PIDLISTFDS, 0, &fds, listSize)
        guard used > 0 else { return [] }
        let actual = Int(used) / MemoryLayout<proc_fdinfo>.stride
        var paths: [String] = []
        for index in 0..<min(actual, fds.count) {
            guard fds[index].proc_fdtype == UInt32(PROX_FDTYPE_VNODE) else { continue }
            var info = vnode_fdinfowithpath()
            let size = proc_pidfdinfo(
                pid_t(pid),
                fds[index].proc_fd,
                PROC_PIDFDVNODEPATHINFO,
                &info,
                Int32(MemoryLayout<vnode_fdinfowithpath>.size)
            )
            guard size > 0 else { continue }
            let path = withUnsafeBytes(of: &info.pvip.vip_path) { raw -> String in
                guard let base = raw.baseAddress else { return "" }
                return String(cString: base.assumingMemoryBound(to: CChar.self))
            }
            if path.hasSuffix(".jsonl"), path.contains("/.codex/sessions/") {
                paths.append(path)
            }
        }
        return paths
    }

}
