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

    private func observedMarkerProcesses() -> [pid_t: Int64] {
        let requiredBytes = proc_listpidspath(
            UInt32(PROC_ALL_PIDS),
            0,
            markerURL.path,
            0,
            nil,
            0
        )
        guard requiredBytes > 0 else { return [:] }
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
        guard returnedBytes > 0 else { return [:] }
        let count = min(Int(returnedBytes) / elementSize, buffer.count / elementSize)
        return buffer.withUnsafeBytes { rawBuffer in
            let pids = rawBuffer.bindMemory(to: pid_t.self)
            return pids.prefix(count).reduce(into: [pid_t: Int64]()) { observed, processID in
                guard processID > 1,
                      processID != getpid(),
                      let startMicroseconds = Self.processStartMicroseconds(processID) else {
                    return
                }
                observed[processID] = startMicroseconds
            }
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
