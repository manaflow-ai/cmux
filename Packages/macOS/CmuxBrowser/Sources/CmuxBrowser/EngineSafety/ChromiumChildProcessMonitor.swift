import Darwin
import Foundation
import os

/// Watches the app's Chromium helper processes (renderer, GPU, utility,
/// extension renderers) and reports each one that ends abnormally.
///
/// CEF reports renderer ends per pane (OnRenderProcessTerminated), but not
/// GPU, utility (network service) or extension process ends: Chromium
/// restarts those itself. This monitor makes them visible
/// (`debug.browser.crashes`) without polling: a kqueue `NOTE_FORK` on the app
/// process fires when anything spawns a child, a rescan of the app's children
/// registers `NOTE_EXEC | NOTE_EXIT | NOTE_EXITSTATUS` on each new one, and
/// the exit event carries the wait status before the child is reaped.
/// Children that are not Chromium helpers (terminal shells) are tracked
/// without identity and their exits are ignored.
///
/// Ported from cmux Next's `CEFChildProcessMonitor`. Start it only once the
/// Chromium engine is running; a WebKit-only session never starts it.
public final class ChromiumChildProcessMonitor: @unchecked Sendable {
    public struct Exit: Sendable, Equatable {
        public var pid: Int32
        public var identity: ChromiumHelperIdentity
        /// Raw `waitpid` status.
        public var status: Int32

        /// Why the helper ended, or nil for a normal end.
        public var abnormalReason: BrowserProcessExit.Reason? {
            BrowserProcessExit.abnormalReason(waitStatus: status)
        }
    }

    // All mutable state below is confined to `queue`.
    private let queue = DispatchQueue(label: "com.cmux.browser.chromium-children")
    private let onExit: @Sendable (Exit) -> Void
    private let logger = Logger(subsystem: "com.cmux.browser", category: "chromium-children")
    private var kq: Int32 = -1
    private var source: (any DispatchSourceRead)?
    /// Children being watched: pid -> helper identity (nil until exec, or
    /// for a child that is not a Chromium helper).
    private var children: [Int32: ChromiumHelperIdentity?] = [:]

    /// Test hook: called on the monitor's queue when it starts watching a child.
    private let onWatch: (@Sendable (Int32) -> Void)?

    public init(onExit: @escaping @Sendable (Exit) -> Void) {
        self.onExit = onExit
        self.onWatch = nil
    }

    init(onExit: @escaping @Sendable (Exit) -> Void, onWatch: @escaping @Sendable (Int32) -> Void) {
        self.onExit = onExit
        self.onWatch = onWatch
    }

    deinit {
        source?.cancel()
    }

    /// Starts watching on the monitor's own queue (idempotent).
    public func start() {
        queue.async { [self] in
            guard kq < 0 else { return }
            let fd = kqueue()
            guard fd >= 0 else {
                logger.error("kqueue failed: \(errno)")
                return
            }
            var event = kevent(
                ident: UInt(getpid()), filter: Int16(EVFILT_PROC), flags: UInt16(EV_ADD | EV_CLEAR),
                fflags: UInt32(NOTE_FORK), data: 0, udata: nil
            )
            guard kevent(fd, &event, 1, nil, 0, nil) == 0 else {
                logger.error("NOTE_FORK watch failed: \(errno)")
                close(fd)
                return
            }
            kq = fd
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler { [weak self] in self?.drain() }
            source.setCancelHandler { close(fd) }
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
                children[pid] = ChromiumHelperIdentity.read(pid: pid)
            }
            if event.fflags & UInt32(NOTE_EXIT) != 0 {
                let identity = children.removeValue(forKey: pid) ?? nil
                guard let identity else { continue }
                onExit(Exit(pid: pid, identity: identity, status: Int32(truncatingIfNeeded: event.data)))
            }
        }
        // Events left beyond this batch keep the kqueue readable, so the
        // source fires again.
        if needsRescan { rescan() }
    }

    private func rescan() {
        var pids = [pid_t](repeating: 0, count: 512)
        let filled = proc_listchildpids(getpid(), &pids, Int32(pids.count * MemoryLayout<pid_t>.stride))
        guard filled > 0 else { return }
        // proc_listchildpids returns a count on current macOS (bytes on
        // older ones); take whichever fits the buffer.
        let count = min(Int(filled), pids.count)
        for pid in pids.prefix(count) where pid > 0 && children[pid] == nil {
            var event = kevent(
                ident: UInt(pid), filter: Int16(EVFILT_PROC), flags: UInt16(EV_ADD | EV_CLEAR),
                fflags: UInt32(NOTE_EXEC) | UInt32(NOTE_EXIT) | UInt32(NOTE_EXITSTATUS), data: 0, udata: nil
            )
            // Fails when the child already exited (and was reaped).
            guard kevent(kq, &event, 1, nil, 0, nil) == 0 else { continue }
            children[pid] = ChromiumHelperIdentity.read(pid: pid)
            onWatch?(pid)
        }
    }
}
