import CmuxFoundation
import Foundation
import os

extension PortScanner {
#if DEBUG
    static func acceptsResult(
        currentRevision: UInt64,
        expectedRevision: UInt64,
        staleMetric: ProcessStaleRejection,
        metrics: ProcessPerformanceMetrics = .shared
    ) -> Bool {
        guard currentRevision == expectedRevision else {
            metrics.recordStaleRejection(staleMetric)
            return false
        }
        return true
    }
#else
    static func acceptsResult(
        currentRevision: UInt64,
        expectedRevision: UInt64,
        staleMetric: ProcessStaleRejection
    ) -> Bool {
        currentRevision == expectedRevision
    }
#endif

    // MARK: - Process helpers

    static func expandAgentProcessTree(
        agentPIDsByWorkspace: [UUID: Set<Int>],
        processSnapshot: CmuxTopProcessSnapshot
    ) -> [Int: Set<UUID>] {
        let normalizedRoots = agentPIDsByWorkspace.reduce(into: [UUID: Set<Int>]()) { partial, item in
            let valid = Set(item.value.filter { $0 > 0 })
            guard !valid.isEmpty else { return }
            partial[item.key] = valid
        }
        guard !normalizedRoots.isEmpty else { return [:] }

        var pidToWorkspaces: [Int: Set<UUID>] = [:]
        for (workspaceId, roots) in normalizedRoots {
            for pid in processSnapshot.expandedPIDs(rootPIDs: roots) {
                pidToWorkspaces[pid, default: []].insert(workspaceId)
            }
        }
        return pidToWorkspaces
    }

    static func pidToTTY(
        panelSnapshot: [PanelKey: String],
        processSnapshot: CmuxTopProcessSnapshot
    ) -> [Int: String] {
        var result: [Int: String] = [:]
        for tty in Set(panelSnapshot.values) {
            for pid in processSnapshot.pids(forTTYName: tty) {
                result[pid] = tty
            }
        }
        return result
    }

    static func scanResult(
        panelSnapshot: [PanelKey: String],
        pidToTTY: [Int: String],
        agentPidToWorkspaces: [Int: Set<UUID>],
        pidToPorts: [Int: Set<Int>]
    ) -> (panelResults: [(PanelKey, [Int])], agentPortsByWorkspace: [UUID: Set<Int>]) {
        var portsByTTY: [String: Set<Int>] = [:]
        for (pid, ports) in pidToPorts {
            if let tty = pidToTTY[pid] {
                portsByTTY[tty, default: []].formUnion(ports)
            }
        }
        let panelResults = panelSnapshot.map { key, tty in
            (key, Array(portsByTTY[tty] ?? []).sorted())
        }
        return (
            panelResults,
            agentPortsByWorkspace(
                agentPidToWorkspaces: agentPidToWorkspaces,
                pidToPorts: pidToPorts
            )
        )
    }

    static func agentPortsByWorkspace(
        agentPidToWorkspaces: [Int: Set<UUID>],
        pidToPorts: [Int: Set<Int>]
    ) -> [UUID: Set<Int>] {
        var result: [UUID: Set<Int>] = [:]
        for (pid, ports) in pidToPorts {
            for workspaceID in agentPidToWorkspaces[pid] ?? [] {
                result[workspaceID, default: []].formUnion(ports)
            }
        }
        return result
    }

    static func scanListeningPortsWithPerformanceProof(
        pids: Set<Int>
    ) -> (scan: PortLsofScanResult, proof: ProcessPerformanceCaptureProof) {
        guard !pids.isEmpty else {
            return (
                PortLsofScanResult(values: [:], globallyComplete: true, incompletePIDs: []),
                .libproc
            )
        }
        var result: [Int: Set<Int>] = [:]
        var incompletePIDs: Set<Int> = []
        for pid in pids.sorted() where pid > 0 {
            let rawPID = pid_t(pid)
            errno = 0
            let requiredBytes = proc_pidinfo(rawPID, PROC_PIDLISTFDS, 0, nil, 0)
            guard requiredBytes > 0 else {
                if errno != 0, PIDPresence.current(pid: rawPID) != .absent {
                    incompletePIDs.insert(pid)
                }
                continue
            }

            // Leave spare entries for descriptors opened between sizing and
            // the second syscall. A truncated list is refreshed on the next
            // bounded scan and never blocks another consumer.
            let requiredCount = Int(requiredBytes) / MemoryLayout<proc_fdinfo>.stride
            let capacity = max(1, requiredCount + 16)
            var descriptors = [proc_fdinfo](repeating: proc_fdinfo(), count: capacity)
            let bufferBytes = Int32(capacity * MemoryLayout<proc_fdinfo>.stride)
            errno = 0
            let usedBytes = proc_pidinfo(
                rawPID,
                PROC_PIDLISTFDS,
                0,
                &descriptors,
                bufferBytes
            )
            guard usedBytes > 0 else {
                if errno != 0, PIDPresence.current(pid: rawPID) != .absent {
                    incompletePIDs.insert(pid)
                }
                continue
            }
            if usedBytes >= bufferBytes {
                incompletePIDs.insert(pid)
            }

            let descriptorCount = min(
                descriptors.count,
                Int(usedBytes) / MemoryLayout<proc_fdinfo>.stride
            )
            for descriptor in descriptors.prefix(descriptorCount)
                where descriptor.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
                var socketInfo = socket_fdinfo()
                errno = 0
                let infoBytes = proc_pidfdinfo(
                    rawPID,
                    descriptor.proc_fd,
                    PROC_PIDFDSOCKETINFO,
                    &socketInfo,
                    Int32(MemoryLayout<socket_fdinfo>.size)
                )
                guard infoBytes == MemoryLayout<socket_fdinfo>.size else {
                    if PIDPresence.current(pid: rawPID) != .absent {
                        incompletePIDs.insert(pid)
                    }
                    continue
                }
                guard let port = listeningTCPPort(from: socketInfo) else {
                    continue
                }
                result[pid, default: []].insert(port)
            }
        }
        return (
            PortLsofScanResult(
                values: result,
                globallyComplete: true,
                incompletePIDs: incompletePIDs
            ),
            .libproc
        )
    }

    static func scanListeningPorts(pids: Set<Int>) -> [Int: Set<Int>] {
        scanListeningPortsWithPerformanceProof(pids: pids).scan.values
    }

    static func listeningTCPPort(from socketInfo: socket_fdinfo) -> Int? {
        guard socketInfo.psi.soi_kind == SOCKINFO_TCP,
              socketInfo.psi.soi_protocol == IPPROTO_TCP,
              socketInfo.psi.soi_proto.pri_tcp.tcpsi_state == TSI_S_LISTEN else {
            return nil
        }
        let networkPort = UInt16(
            truncatingIfNeeded: socketInfo.psi.soi_proto.pri_tcp.tcpsi_ini.insi_lport
        )
        let port = Int(UInt16(bigEndian: networkPort))
        return port > 0 ? port : nil
    }
}
