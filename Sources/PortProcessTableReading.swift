import CmuxCore
import Foundation

/// Reads the process-table facts a port scan joins against: which processes
/// sit on a panel's terminal, and which process parents which.
///
/// The production reader is ``KernelPortProcessTable``, which asks the kernel
/// directly. Tests substitute a fixture that returns fixed mappings, suspends,
/// or reports incomplete evidence.
protocol PortProcessTableReading: Sendable {
    /// Maps each process attached to one of the requested terminals to that
    /// terminal's canonical name.
    ///
    /// - Parameter ttyNames: Terminal names as panels registered them, either
    ///   bare (`ttys001`) or as a full device path (`/dev/ttys001`).
    /// - Returns: `[pid: canonical tty name]`, with names canonicalized by
    ///   `PortScanner.canonicalTTYName`, plus whether the answer covers every
    ///   requested terminal. A terminal that no longer exists holds no
    ///   processes and does not make the answer incomplete.
    func processesOnTerminals(
        named ttyNames: [String]
    ) async -> (values: [Int: String], completeness: PortScanCompleteness)

    /// Maps every live process to its parent.
    ///
    /// - Returns: `[pid: parent pid]` plus whether the process table was read
    ///   in full.
    func parentsByPID() async -> (values: [Int: Int], completeness: PortScanCompleteness)
}
