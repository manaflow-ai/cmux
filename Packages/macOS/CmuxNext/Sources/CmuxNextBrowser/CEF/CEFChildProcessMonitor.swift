import CmuxNextCompat
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
nonisolated final class CEFChildProcessMonitor: @unchecked Sendable {
    struct Exit: Sendable, Equatable {
        var pid: Int32
        var processType: String
        var subType: String?
        var isExtension: Bool
        /// Raw `waitpid` status.
        var status: Int32
        /// A renderer's `--renderer-client-id` (its render process host id, which RENDER_TERMINATED names too);
        /// nil for every other helper.
        var rendererClientID: Int32?
        /// The browsers a renderer hosted frames for other than their main frame (``CEFSubframeRenderers``).
        var subframeBrowsers: Set<Int32> = []
    }

    private let queue = DispatchQueue(label: "com.cmuxterm.app.next.cef-children", qos: .userInitiated)
    private let onExit: @Sendable (Exit) -> Void
    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "cef-children")
    private var kq: Int32 = -1
    private var source: (any DispatchSourceRead)?
    /// Children being watched: pid -> helper identity (nil until exec).
    private var children: [Int32: CEFHelperIdentity?] = [:]
    /// The renderers' frames other than a browser's main frame (``subframe(_:browser:client:attached:)``).
    private var subframes = CEFSubframeRenderers()

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
            // SAFETY: udata is NULL; the kernel never dereferences it.
            var event = unsafe kevent(ident: UInt(getpid()), filter: Int16(EVFILT_PROC), flags: UInt16(EV_ADD | EV_CLEAR),
                                      fflags: UInt32(NOTE_FORK), data: 0, udata: nil)
            // SAFETY: one change read from `event`, no event list.
            guard unsafe kevent(fd, &event, 1, nil, 0, nil) == 0 else {
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
        let room = Int32(events.count)
        // SAFETY: the kernel writes at most `room` events into the array's buffer and reads `zero` during the call.
        let count = unsafe kevent(kq, nil, 0, &events, room, &zero)
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
                let subframeBrowsers = identity.rendererClientID.map { subframes.ended(client: $0) } ?? []
                onExit(Exit(pid: pid, processType: identity.processType, subType: identity.subType,
                            isExtension: identity.isExtension, status: Int32(truncatingIfNeeded: event.data),
                            rendererClientID: identity.rendererClientID, subframeBrowsers: subframeBrowsers))
            }
        }
        if needsRescan { rescan() }
    }

    /// Frame `frame` of `browser`, not its main frame, attached to or detached from renderer `client`
    /// (SUBFRAME_RENDERER, in Chromium's order): that renderer's abnormal end names `browser` in
    /// ``Exit/subframeBrowsers``. A detach is read against the renderer's process on the monitor's queue,
    /// where its exit event lands: one that is ending or ended lost the frame to its death.
    func subframe(_ frame: String, browser: Int32, client: Int32, attached: Bool) {
        queue.async { [self] in
            if attached { return subframes.attached(frame, client: client, browser: browser) }
            let pid = children.first { $0.value?.rendererClientID == client }?.key
            subframes.detached(frame, client: client, browser: browser, rendererExiting: pid.map(Self.isExiting) ?? false)
        }
    }

    /// Whether child `pid` is ending or ended: gone (reaped before its exit event drained), a zombie,
    /// or in exit (`P_WEXIT`, set before its ports close, which is how Chromium hears of the death).
    static func isExiting(_ pid: pid_t) -> Bool {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        // SAFETY: sysctl reads the mib.count names of `mib` and writes at most `size` bytes (one kinfo_proc) into `info`
        // and the size it wrote into `size`; all three are locals live for the call.
        guard unsafe blockingSysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0 else { return false }
        // An empty answer: no process has the pid any more.
        guard size > 0 else { return true }
        return info.kp_proc.p_stat == SZOMB || info.kp_proc.p_flag & P_WEXIT != 0
    }

    private func rescan() {
        var pids = [pid_t](repeating: 0, count: 256)
        let room = Int32(pids.count * MemoryLayout<pid_t>.stride)
        // SAFETY: the kernel writes at most `room` bytes, the array's size, into its buffer during the call.
        let bytes = unsafe proc_listchildpids(getpid(), &pids, room)
        guard bytes > 0 else { return }
        // proc_listchildpids returns a count on current macOS (bytes on
        // older ones); take whichever fits the buffer.
        let count = min(Int(bytes), pids.count)
        for pid in pids.prefix(count) where pid > 0 && children[pid] == nil {
            // SAFETY: udata is NULL; the kernel never dereferences it.
            var event = unsafe kevent(ident: UInt(pid), filter: Int16(EVFILT_PROC), flags: UInt16(EV_ADD | EV_CLEAR),
                                      fflags: UInt32(NOTE_EXEC) | UInt32(NOTE_EXIT) | UInt32(NOTE_EXITSTATUS), data: 0, udata: nil)
            // Fails when the child already exited (and was reaped).
            // SAFETY: one change read from `event`, no event list.
            guard unsafe kevent(kq, &event, 1, nil, 0, nil) == 0 else { continue }
            children[pid] = CEFHelperIdentity.read(pid: pid)
        }
    }
}

/// A Chromium helper's `--type` and related switches, read from its argv.
nonisolated struct CEFHelperIdentity: Equatable, Sendable {
    var processType: String
    var subType: String?
    var isExtension: Bool
    /// `--renderer-client-id`: the render process host id Chromium names a renderer's frames by, and RENDER_TERMINATED too.
    var rendererClientID: Int32?

    static func read(pid: Int32) -> CEFHelperIdentity? {
        parse(arguments(pid: pid))
    }

    static func parse(_ arguments: [String]) -> CEFHelperIdentity? {
        var type: String?
        var subType: String?
        var isExtension = false
        var rendererClientID: Int32?
        for argument in arguments {
            if argument.hasPrefix("--type=") {
                type = String(argument.dropFirst("--type=".count))
            } else if argument.hasPrefix("--utility-sub-type=") {
                subType = String(argument.dropFirst("--utility-sub-type=".count))
            } else if argument == "--extension-process" {
                isExtension = true
            } else if argument.hasPrefix("--renderer-client-id=") {
                rendererClientID = Int32(argument.dropFirst("--renderer-client-id=".count))
            }
        }
        guard let type, !type.isEmpty else { return nil }
        return CEFHelperIdentity(processType: type, subType: subType, isExtension: isExtension, rendererClientID: rendererClientID)
    }

    /// argv of `pid` from KERN_PROCARGS2: argc, exec path, padding, argv.
    static func arguments(pid: Int32) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        // SAFETY: reads the 3-int name; a NULL old buffer only writes the size it needs into `size`.
        guard unsafe blockingSysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return [] }
        var buffer = [UInt8](repeating: 0, count: size)
        // SAFETY: `size` is the array's length; the kernel writes at most that many bytes and the length it wrote.
        guard unsafe blockingSysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return [] }
        return parseProcArgs(Array(buffer.prefix(size)))
    }

    static func parseProcArgs(_ buffer: [UInt8]) -> [String] {
        let intSize = MemoryLayout<Int32>.size
        guard buffer.count > intSize else { return [] }
        // argc: the first Int32, little-endian (KERN_PROCARGS2 on arm64 and x86_64).
        let argc = Int(Int32(bitPattern: buffer.prefix(intSize).reversed().reduce(UInt32(0)) { $0 << 8 | UInt32($1) }))
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
