import CmuxCore
import CmuxFoundation
import Darwin
import Foundation

/// Reads a port scan's process table from the kernel instead of running `ps`.
///
/// The scanner used to spawn `/bin/ps -t <ttys>` for every panel scan and
/// `/bin/ps -ax` up to twice per agent scan. Agent scans repeat every two
/// seconds while an agent runs and panel scans burst after every shell
/// command, so cmux forked a process many times a minute, and endpoint
/// security tools log every one of those execs. This reader answers the same
/// two questions in process with one `proc_listallpids` enumeration per call
/// (``DarwinProcessEnumerator``) plus a `stat` of each requested terminal.
///
/// Completeness follows the process list, not every record in it: a PID that
/// disappears between listing and reading has exited, so it can neither hold a
/// port nor parent a process that could. Only a truncated or unreadable list,
/// or a terminal that exists but cannot be inspected, makes an answer
/// incomplete.
///
/// Each call blocks its cooperative thread for the length of one enumeration,
/// a few milliseconds even on a busy machine. A panel scan makes up to four
/// enumerations and can overlap one agent scan, so at most a handful run at
/// once, briefly; that is still far cheaper than forking `ps`, so they run
/// inline rather than on a dedicated queue, like the listening-port lookup.
///
/// ```swift
/// let table = KernelPortProcessTable()
/// let parents = await table.parentsByPID()
/// ```
struct KernelPortProcessTable: PortProcessTableReading {
    /// The `e_tdev` a process without a controlling terminal reports.
    private static let noTerminalDevice = UInt32.max
    private static let deviceDirectory = "/dev/"

    private let listProcesses: @Sendable () -> DarwinProcessListing
    private let terminalDevice: @Sendable (String) -> PortTerminalDeviceLookup

    /// Creates a reader over injectable kernel seams.
    ///
    /// - Parameters:
    ///   - listProcesses: Captures one process listing. Defaults to
    ///     ``DarwinProcessEnumerator``, which reads every process the caller
    ///     can see, including other users' through its public `sysctl` fallback.
    ///   - terminalDevice: Resolves a canonical terminal name such as `ttys001`
    ///     to its device number. Defaults to a `stat` of `/dev/<name>`.
    init(
        listProcesses: @escaping @Sendable () -> DarwinProcessListing = {
            DarwinProcessEnumerator().capture()
        },
        terminalDevice: @escaping @Sendable (String) -> PortTerminalDeviceLookup = {
            KernelPortProcessTable.resolveTerminalDevice(named: $0)
        }
    ) {
        self.listProcesses = listProcesses
        self.terminalDevice = terminalDevice
    }

    func processesOnTerminals(
        named ttyNames: [String]
    ) async -> (values: [Int: String], completeness: PortScanCompleteness) {
        var namesByDevice: [UInt32: String] = [:]
        var everyTerminalReadable = true
        for ttyName in ttyNames {
            let canonicalName = PortScanner.canonicalTTYName(ttyName)
            switch terminalDevice(canonicalName) {
            case .device(let device):
                namesByDevice[device] = canonicalName
            case .absent:
                // A freed pty holds no processes. Dropping it keeps one closed
                // terminal from costing every other panel its evidence.
                continue
            case .unreadable:
                everyTerminalReadable = false
            }
        }
        guard !namesByDevice.isEmpty else {
            // Every terminal is gone (authoritative emptiness) or unreadable.
            return ([:], everyTerminalReadable ? .complete : .incomplete)
        }

        let listing = listProcesses()
        var values: [Int: String] = [:]
        for process in listing.processes
        where process.pbi_pid > 0 && process.e_tdev != Self.noTerminalDevice {
            guard let ttyName = namesByDevice[process.e_tdev] else { continue }
            values[Int(process.pbi_pid)] = ttyName
        }
        let complete = everyTerminalReadable && Self.coversEveryProcess(listing)
        return (values, complete ? .complete : .incomplete)
    }

    func parentsByPID() async -> (values: [Int: Int], completeness: PortScanCompleteness) {
        let listing = listProcesses()
        var values: [Int: Int] = [:]
        for process in listing.processes where process.pbi_pid > 0 {
            values[Int(process.pbi_pid)] = Int(process.pbi_ppid)
        }
        return (values, Self.coversEveryProcess(listing) ? .complete : .incomplete)
    }

    /// Whether a listing names every live process. An empty listing means the
    /// PID list could not be read, since the reader itself is always listed.
    private static func coversEveryProcess(_ listing: DarwinProcessListing) -> Bool {
        !listing.isTruncated && !listing.processes.isEmpty
    }

    /// Resolves `/dev/<ttyName>` to the device number processes on that
    /// terminal report. Anything other than a character device is not a
    /// terminal, so it is treated like a missing one.
    static func resolveTerminalDevice(named ttyName: String) -> PortTerminalDeviceLookup {
        var info = stat()
        guard stat(deviceDirectory + ttyName, &info) == 0 else {
            switch errno {
            case ENOENT, ENOTDIR:
                return .absent
            default:
                return .unreadable
            }
        }
        guard mode_t(info.st_mode) & mode_t(S_IFMT) == mode_t(S_IFCHR) else { return .absent }
        return .device(UInt32(bitPattern: info.st_rdev))
    }
}
