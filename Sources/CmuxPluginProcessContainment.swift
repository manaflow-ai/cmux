import Darwin
import Foundation

/// Keeps an inherited, private marker for one plugin process tree.
///
/// The marker is opened by the launch gate on a descriptor without
/// `FD_CLOEXEC`, so ordinary children—including double-forked descendants—keep
/// a discoverable lease. Revocation combines the marker holder list with the
/// validated process group and rechecks each process start time before sending
/// a signal, avoiding PID reuse while containing descendants that leave the
/// original group.
struct CmuxPluginProcessContainment: Sendable {
    private static let markerPrefix = "cmux-plugin-containment-"
    private static let maximumObservedProcesses = 256
    let markerURL: URL

    init(
        fileManager: FileManager = .default,
        temporaryDirectory: URL? = nil
    ) throws {
        let directory = temporaryDirectory ?? fileManager.temporaryDirectory
        let markerURL = directory.appendingPathComponent(
            "\(Self.markerPrefix)\(UUID().uuidString).marker",
            isDirectory: false
        )
        guard fileManager.createFile(atPath: markerURL.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        do {
            try fileManager.setAttributes(
                [.posixPermissions: NSNumber(value: 0o600)],
                ofItemAtPath: markerURL.path
            )
        } catch {
            try? fileManager.removeItem(at: markerURL)
            throw error
        }
        self.markerURL = markerURL
    }

    /// Sends bounded termination signals to the group and every marker holder.
    func terminate(
        rootProcessID: pid_t,
        processGroupID: pid_t,
        expectedRootStartMicroseconds: Int64?
    ) {
        let groupIsCurrent = processGroupID > 1
            && expectedRootStartMicroseconds.map {
                Self.processStartMicroseconds(rootProcessID) == $0
            } ?? false
        let firstPass = observedMarkerProcesses()
        if groupIsCurrent {
            _ = Darwin.kill(-processGroupID, SIGTERM)
        }
        signal(firstPass, with: SIGTERM)

        // A child can fork while the first signal fan-out is in flight. Take a
        // second bounded snapshot before escalating, without sleeping or
        // polling an unbounded process list.
        let secondPass = observedMarkerProcesses()
        if groupIsCurrent {
            _ = Darwin.kill(-processGroupID, SIGKILL)
        }
        var allObserved = firstPass
        for (processID, startMicroseconds) in secondPass {
            allObserved[processID] = startMicroseconds
        }
        signal(allObserved, with: SIGKILL)
    }

    /// Removes the marker after the supervisor observes the root exit.
    func cleanup() {
        try? FileManager.default.removeItem(at: markerURL)
    }

    /// Removes the marker only after no descendant still holds its lease.
    @discardableResult
    func cleanupIfUnheld() -> Bool {
        guard !Self.anyProcessHoldsMarker(at: markerURL) else { return false }
        cleanup()
        return true
    }

    /// Returns whether `processID` still holds the private marker, or `nil`
    /// when the kernel process-list lookup could not be completed.
    static func processHoldsMarker(_ processID: pid_t, at markerURL: URL) -> Bool? {
        markerHolderProcessIDs(at: markerURL)?.contains(processID)
    }

    /// Returns whether any live process still holds the private marker.
    static func anyProcessHoldsMarker(at markerURL: URL) -> Bool {
        guard let holders = markerHolderProcessIDs(at: markerURL) else {
            // An unavailable process-list lookup must retain the marker; it is
            // safer to defer cleanup than to lose a live descendant lease.
            return true
        }
        return !holders.isEmpty
    }

    /// Reclaims markers left by a crash while preserving live process leases.
    static func reapStaleMarkers(
        fileManager: FileManager = .default,
        temporaryDirectory: URL? = nil
    ) {
        let directory = temporaryDirectory ?? fileManager.temporaryDirectory
        let entries = (try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        for marker in entries.prefix(Self.maximumObservedProcesses) {
            guard marker.lastPathComponent.hasPrefix(Self.markerPrefix),
                  marker.pathExtension == "marker",
                  let holders = Self.markerHolderProcessIDs(at: marker),
                  holders.isEmpty else {
                continue
            }
            try? fileManager.removeItem(at: marker)
        }
    }

    private func observedMarkerProcesses() -> [pid_t: Int64] {
        guard let processIDs = Self.markerHolderProcessIDs(at: markerURL) else {
            return [:]
        }
        return processIDs.reduce(into: [pid_t: Int64]()) { observed, processID in
            guard processID > 1,
                  processID != getpid(),
                  let startMicroseconds = Self.processStartMicroseconds(processID) else {
                return
            }
            observed[processID] = startMicroseconds
        }
    }

    private static func markerHolderProcessIDs(at markerURL: URL) -> [pid_t]? {
        let requiredBytes = proc_listpidspath(
            UInt32(PROC_ALL_PIDS),
            0,
            markerURL.path,
            0,
            nil,
            0
        )
        guard requiredBytes >= 0 else { return nil }
        guard requiredBytes > 0 else { return [] }
        let elementSize = MemoryLayout<pid_t>.stride
        let capacity = min(
            max(elementSize, Int(requiredBytes) + elementSize * 8),
            elementSize * Self.maximumObservedProcesses
        )
        var buffer = [UInt8](repeating: 0, count: capacity)
        let returnedBytes = buffer.withUnsafeMutableBytes { rawBuffer in
            proc_listpidspath(
                UInt32(PROC_ALL_PIDS),
                0,
                markerURL.path,
                0,
                rawBuffer.baseAddress,
                Int32(rawBuffer.count)
            )
        }
        guard returnedBytes >= 0 else { return nil }
        guard returnedBytes > 0 else { return [] }
        let count = min(Int(returnedBytes) / elementSize, buffer.count / elementSize)
        return buffer.withUnsafeBytes { rawBuffer in
            let pids = rawBuffer.bindMemory(to: pid_t.self)
            return Array(pids.prefix(count))
        }
    }

    private func signal(_ processes: [pid_t: Int64], with signal: Int32) {
        for (processID, startMicroseconds) in processes {
            guard Self.processStartMicroseconds(processID) == startMicroseconds else {
                continue
            }
            _ = Darwin.kill(processID, signal)
        }
    }

    private static func processStartMicroseconds(_ processID: pid_t) -> Int64? {
        guard processID > 1 else { return nil }
        var info = proc_bsdinfo()
        let expectedSize = Int32(MemoryLayout<proc_bsdinfo>.stride)
        guard proc_pidinfo(
            processID,
            PROC_PIDTBSDINFO,
            0,
            &info,
            expectedSize
        ) == expectedSize else {
            return nil
        }
        return Int64(info.pbi_start_tvsec) * 1_000_000
            + Int64(info.pbi_start_tvusec)
    }
}
