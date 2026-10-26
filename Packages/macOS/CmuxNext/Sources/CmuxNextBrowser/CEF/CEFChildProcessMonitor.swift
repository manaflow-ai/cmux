import Darwin
import Foundation
import os

/// Watches the app's Chromium helper processes (renderer, GPU, utility,
/// extension renderers) and reports each one that ends abnormally.
///
/// CEF reports renderer ends per tab (OnRenderProcessTerminated), but not
/// GPU, utility (network service) or extension process ends: Chromium
/// restarts those itself. This monitor makes them visible (`debug.crashes`,
/// crash reports) without polling: a kqueue `NOTE_FORK` on the app process
/// fires when Chromium spawns a helper (posix_spawn counts), a rescan of
/// the app's children registers `NOTE_EXEC | NOTE_EXIT | NOTE_EXITSTATUS`
/// on each new one, and the exit event carries the wait status before
/// Chromium reaps the child.
///
/// In host mode Chromium's browser process is the Chromium host, so its
/// helpers are the host's children: the host runs the same watch and sends
/// each exit as HELPER_EXIT (`ChromiumHostProcessMirror`).
nonisolated final class CEFChildProcessMonitor: @unchecked Sendable {
    struct Exit: Sendable, Equatable {
        var pid: Int32
        var processType: String
        var subType: String?
        var isExtension: Bool
        /// Raw `waitpid` status.
        var status: Int32

        /// The signal that ended the helper (`WTERMSIG`), nil when it exited or only stopped.
        var signal: Int32? {
            let low = status & 0x7f
            return low == 0 || low == 0x7f ? nil : low
        }

        /// Nil for a normal end (exit 0, or SIGTERM, which Chromium sends to
        /// helpers it no longer needs); otherwise why the helper ended.
        var abnormalReason: BrowserProcessExit.Reason? {
            guard let signal else {
                // An exit (or a stop, which is not an end).
                return status & 0x7f == 0 && (status >> 8) & 0xff != 0 ? .abnormal : nil
            }
            switch signal {
            case SIGTERM: return nil
            case SIGKILL: return .killed
            default: return .crashed
            }
        }

        /// One `.process` record in `crashLog` when the helper ended
        /// abnormally (`debug.crashes`); false for a normal end.
        @MainActor @discardableResult
        func record(in crashLog: BrowserCrashLog, logger: Logger) -> Bool {
            guard let reason = abnormalReason else { return false }
            let type = isExtension ? "extension" : processType
            logger.error("helper ended type=\(type, privacy: .public) sub=\(subType ?? "-", privacy: .public) pid=\(pid) reason=\(reason.rawValue, privacy: .public) status=\(status) signal=\(signal ?? 0)")
            crashLog.append(BrowserCrashRecord(processType: type, subType: subType, pid: pid, reason: reason,
                                               code: Int(status), source: .process))
            return true
        }
    }

    private let queue = DispatchQueue(label: "com.cmuxterm.app.next.cef-children")
    private let onExit: @Sendable (Exit) -> Void
    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "cef-children")
    private var kq: Int32 = -1
    private var source: (any DispatchSourceRead)?
    /// Children being watched: pid -> helper identity (nil until exec).
    private var children: [Int32: CEFHelperIdentity?] = [:]

    init(onExit: @escaping @Sendable (Exit) -> Void) {
        self.onExit = onExit
    }

    /// Starts watching on the monitor's own queue (idempotent).
    func start() {
        queue.async { [self] in
            guard kq < 0 else { return }
            let fd = kqueue()
            guard fd >= 0 else {
                logger.error("kqueue failed: \(errno)")
                return
            }
            var event = kevent(ident: UInt(getpid()), filter: Int16(EVFILT_PROC), flags: UInt16(EV_ADD | EV_CLEAR),
                               fflags: UInt32(NOTE_FORK), data: 0, udata: nil)
            guard kevent(fd, &event, 1, nil, 0, nil) == 0 else {
                logger.error("NOTE_FORK watch failed: \(errno)")
                close(fd)
                return
            }
            kq = fd
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler { [weak self] in self?.drain() }
            source.resume()
            self.source = source
            rescan()
        }
    }

    private func drain() {
        var events = Array(repeating: Darwin.kevent(), count: 16)
        var zero = timespec(tv_sec: 0, tv_nsec: 0)
        let count = kevent(kq, nil, 0, &events, Int32(events.count), &zero)
        guard count > 0 else { return }
        var needsRescan = false
        for event in events.prefix(Int(count)) {
            let pid = Int32(truncatingIfNeeded: event.ident)
            if pid == getpid() {
                needsRescan = needsRescan || event.fflags & UInt32(NOTE_FORK) != 0
                continue
            }
            if event.fflags & UInt32(NOTE_EXEC) != 0 {
                children[pid] = CEFHelperIdentity.read(pid: pid)
            }
            if event.fflags & UInt32(NOTE_EXIT) != 0 {
                let identity = children.removeValue(forKey: pid) ?? nil
                guard let identity else { continue }
                onExit(Exit(pid: pid, processType: identity.processType, subType: identity.subType,
                            isExtension: identity.isExtension, status: Int32(truncatingIfNeeded: event.data)))
            }
        }
        if needsRescan { rescan() }
    }

    private func rescan() {
        var pids = [pid_t](repeating: 0, count: 256)
        let bytes = proc_listchildpids(getpid(), &pids, Int32(pids.count * MemoryLayout<pid_t>.stride))
        guard bytes > 0 else { return }
        // proc_listchildpids returns a count on current macOS (bytes on
        // older ones); take whichever fits the buffer.
        let count = min(Int(bytes), pids.count)
        for pid in pids.prefix(count) where pid > 0 && children[pid] == nil {
            var event = kevent(ident: UInt(pid), filter: Int16(EVFILT_PROC), flags: UInt16(EV_ADD | EV_CLEAR),
                               fflags: UInt32(NOTE_EXEC) | UInt32(NOTE_EXIT) | UInt32(NOTE_EXITSTATUS), data: 0, udata: nil)
            // Fails when the child already exited (and was reaped).
            guard kevent(kq, &event, 1, nil, 0, nil) == 0 else { continue }
            children[pid] = CEFHelperIdentity.read(pid: pid)
        }
    }
}

/// Who reports a runtime's Chromium helpers: exactly one per backend.
enum CEFHelperWatch {
    /// In process: the helpers are the app's children, watched by kqueue.
    case monitor(CEFChildProcessMonitor)
    /// Host mode: the helpers are the host's children; it reports them in frames.
    case host(ChromiumHostProcessMirror)

    var hostMirror: ChromiumHostProcessMirror? {
        if case .host(let mirror) = self { return mirror }
        return nil
    }
}

/// A Chromium helper's `--type` and related switches, read from its argv.
nonisolated struct CEFHelperIdentity: Equatable, Sendable {
    var processType: String
    var subType: String?
    var isExtension: Bool

    static func read(pid: Int32) -> CEFHelperIdentity? {
        parse(arguments(pid: pid))
    }

    static func parse(_ arguments: [String]) -> CEFHelperIdentity? {
        var type: String?
        var subType: String?
        var isExtension = false
        for argument in arguments {
            if argument.hasPrefix("--type=") {
                type = String(argument.dropFirst("--type=".count))
            } else if argument.hasPrefix("--utility-sub-type=") {
                subType = String(argument.dropFirst("--utility-sub-type=".count))
            } else if argument == "--extension-process" {
                isExtension = true
            }
        }
        guard let type, !type.isEmpty else { return nil }
        return CEFHelperIdentity(processType: type, subType: subType, isExtension: isExtension)
    }

    /// argv of `pid` from KERN_PROCARGS2: argc, exec path, padding, argv.
    static func arguments(pid: Int32) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return [] }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return [] }
        return parseProcArgs(Array(buffer.prefix(size)))
    }

    static func parseProcArgs(_ buffer: [UInt8]) -> [String] {
        let intSize = MemoryLayout<Int32>.size
        guard buffer.count > intSize else { return [] }
        let argc = buffer.prefix(intSize).withUnsafeBytes { Int($0.loadUnaligned(as: Int32.self)) }
        guard argc > 0 else { return [] }
        var index = intSize
        // Skip the exec path and the NUL padding after it.
        while index < buffer.count, buffer[index] != 0 { index += 1 }
        while index < buffer.count, buffer[index] == 0 { index += 1 }
        var result: [String] = []
        while index < buffer.count, result.count < argc {
            let start = index
            while index < buffer.count, buffer[index] != 0 { index += 1 }
            result.append(String(decoding: buffer[start..<index], as: UTF8.self))
            index += 1
        }
        return result
    }
}
