#if DEBUG || CMUX_BENCH_HOOKS
// The Chromium host app ships in Debug builds only (embed-cef.sh), and so does its Swift side.
import CmuxNextCompat
import Darwin

/// cmux's writer of the input ring to the Chromium Host
/// (plans/cmux-next/chrome-parity/p01-process.md 3.1).
///
/// Keys, clicks, pointer moves and wheel ticks go to the host through 4,096
/// frames of 64 bytes in a shared memory region, not the control socket. One
/// write stores the frame and release-stores the tail: no lock, no system call,
/// unless the host's reader is parked, when it also sends one Mach message
/// with a zero timeout (``ChromiumHostInputDoorbell``, a Mach port as Mojo's
/// mojo/core/channel_mac.cc uses; the host's reader runs at user-interactive
/// QoS itself, so it needs no override from the message). The layout, the
/// park protocol and the host's reader are
/// `ChromiumHost/src/chromium_host_input_ring.h`; both sides check the same
/// golden bytes (`ChromiumHostInputRingTests`,
/// `chromium_host_input_ring_test.cpp`).
///
/// A full ring (a host whose UI thread stopped) never makes a write wait: the
/// frame goes to this writer's backlog, which the next write or
/// ``flushBacklog()`` moves into the ring first, so the host still gets every
/// frame in order. Keys, clicks and every frame that is not a move or a wheel
/// tick wait there and are never dropped: only the person's Reload or the
/// supervisor's 60 s ceiling ends a host that stopped taking them
/// (p01-process.md 3.1, Bounds). When a page's newest waiting frame is a
/// move, its next move replaces it; when it is a wheel tick, the next tick's
/// deltas add up into it, as the host's `FrameQueue` coalesces. That is
/// coalescing by page, not by the backlog's last entry, so moves of one page
/// interleaved with another page's frames still fold, and a page's frames
/// never pass each other (its seqs keep rising). Over ``coalescableLimit``
/// waiting moves and wheel ticks, one that cannot fold in is dropped and
/// counted (``Stats/dropped``), as the control channel's quota counts its excess.
///
/// Main actor: the one writer of a single-producer ring is the thread that
/// receives `NSEvent`s.
final class ChromiumHostInputRing {
    // The layout of chromium_host_input_ring.h.
    nonisolated static let magic: UInt32 = 0x5249_4d43  // "CMIR"
    nonisolated static let version: UInt32 = 1
    nonisolated static let capacity: UInt64 = 4_096
    nonisolated static let frameSize = 64
    nonisolated static let tailOffset = 128
    nonisolated static let headOffset = 256
    nonisolated static let parkedOffset = 384
    nonisolated static let framesOffset = 512
    nonisolated static let ringBytes = 512 + 4_096 * 64
    /// The host's descriptor of the region (`kRingFd`).
    nonisolated static let hostDescriptor: Int32 = 5
    /// Moves and wheel ticks the backlog holds; keys and clicks have no bound here.
    nonisolated static let coalescableLimit = 4_096

    /// What one ``write(_:browser:)`` did.
    nonisolated enum Push: Equatable, Sendable {
        /// In the ring.
        case written
        /// In the backlog (the ring is full), or folded into a waiting move or
        /// wheel tick there.
        case spilled
        /// Not written and counted: a frame with a payload (ring frames have none).
        case refused
        /// A move or wheel tick over ``coalescableLimit`` that could not fold
        /// into a waiting one: dropped and counted. Keys and clicks never are.
        case dropped
        /// The host moved its head to a position no reader can be at; every
        /// later write is refused too (the owner ends the host).
        case broken
    }

    /// What one ``flushBacklog()`` did.
    nonisolated enum Flush: Equatable, Sendable {
        case drained
        /// This many frames still wait: the ring is full.
        case waiting(Int)
        case broken
    }

    /// Counts for `debug.chromium_host`.
    nonisolated struct Stats: Equatable, Sendable {
        var written: UInt64 = 0
        var doorbells: UInt64 = 0
        var spilled: UInt64 = 0
        var coalesced: UInt64 = 0
        var refused: UInt64 = 0
        /// Moves and wheel ticks dropped over ``coalescableLimit``.
        var dropped: UInt64 = 0
    }


    private(set) var stats = Stats()
    private(set) var isBroken = false
    private let mapping: Mapping
    private let tailSlot: AtomicPointerSlot
    private let headSlot: AtomicPointerSlot
    private let parkedSlot: AtomicPointerSlot
    private var tail: UInt64
    /// The last head read: the writer reads the reader's cache line only when
    /// the ring looks full.
    private var head: UInt64
    private var nextSeq: UInt32 = 1
    private var doorbell: (any ChromiumHostInputDoorbell)?
    /// The reader parked before the doorbell was attached.
    private var ringWhenAttached = false
    /// Frames waiting for room in the ring, oldest first, from `backlogHead`.
    private var backlog: [ChromiumHostFrame] = []
    private var backlogHead = 0
    /// The position of `backlog[0]` since this writer began (compaction
    /// moves it), so `foldInto` positions stay valid.
    private var backlogStart = 0
    /// Per page (client browser id), the position of its newest waiting
    /// frame when that is a move or a wheel tick: the next one of the same
    /// kind folds into it. Any other frame of the page ends the entry, so a
    /// page's frames never pass each other.
    private var foldInto: [Int32: Int] = [:]
    /// Moves and wheel ticks in the backlog.
    private var coalescableWaiting = 0
    /// Compact the backlog once this many frames left it from the front.
    private static let compactAfter = 1_024

    /// Maps the ring in `fd` (``ChromiumHostInputRingRegion/fd``; the caller
    /// keeps and closes the descriptor). Rings `doorbell` when the reader
    /// parked; nil until ``attach(_:)``.
    init(region fd: Int32, doorbell: (any ChromiumHostInputDoorbell)?) throws(ChromiumHostInputRingError) {
        let mapping = try Mapping(fd: fd)
        // SAFETY: the mapping holds `ringBytes` (Mapping checked the region's size), more than the header read.
        guard unsafe Self.isRing(UnsafeRawPointer(mapping.base)) else { throw .notARing }
        self.mapping = mapping
        tailSlot = mapping.slot(Self.tailOffset)
        headSlot = mapping.slot(Self.headOffset)
        parkedSlot = mapping.slot(Self.parkedOffset)
        tail = tailSlot.load(ordering: .relaxed)
        head = headSlot.load(ordering: .acquiring)
        self.doorbell = doorbell
    }

    /// The doorbell, once looked up (``ChromiumHostMachDoorbell/lookUp(name:)``
    /// off the main thread, after the host's HELLO). Rings it at once when the
    /// reader parked before.
    func attach(_ doorbell: any ChromiumHostInputDoorbell) {
        self.doorbell = doorbell
        if ringWhenAttached {
            ringWhenAttached = false
            ring()
        }
    }

    /// Frames waiting in the backlog.
    var backlogCount: Int { backlog.count - backlogHead }

    /// Writes `frame` for the page whose client browser id is `browser`; it
    /// takes the next input sequence number. Never blocks.
    @discardableResult
    func write(_ frame: ChromiumHostFrame, browser: Int32) -> Push {
        let seq = nextSeq
        nextSeq &+= 1
        return write(frame, browser: browser, seq: seq, ctlSeq: frame.ctlSeq)
    }

    /// Writes `frame` for `browser` with the input seq and control seq the remote shim gave it
    /// (`cmux_remote_shim_order_input`, task 092): the host's ordered stream dispatches it only
    /// after that control message. Never blocks.
    @discardableResult
    func write(_ frame: ChromiumHostFrame, browser: Int32, seq: UInt32, ctlSeq: UInt32) -> Push { // perf-hot: 1us cef-host-input-ring (every key, click, move and wheel to the Chromium Host)
        guard !isBroken else { return .broken }
        guard frame.payload.isEmpty else {
            stats.refused += 1
            return .refused
        }
        var stamped = frame
        stamped.seq = seq
        stamped.t1 = UInt64(UInt32(bitPattern: browser))
        stamped.ctlSeq = ctlSeq
        if backlogCount > 0, flushBacklog() == .broken { return .broken }
        if backlogCount == 0 {
            switch put(stamped) {
            case .written: return .written
            case .broken: return .broken
            case .full: break
            }
        }
        return spill(stamped)
    }

    /// Moves backlog frames into the ring, oldest first, while it has room.
    /// The next write does this too; an owner with no write coming (the host
    /// took input) calls it so the backlog reaches the host.
    @discardableResult
    func flushBacklog() -> Flush {
        while backlogHead < backlog.count {
            switch put(backlog[backlogHead]) {
            case .written:
                if Self.isCoalescable(backlog[backlogHead]) { coalescableWaiting -= 1 }
                backlogHead += 1
            case .full:
                compactBacklog()
                return .waiting(backlogCount)
            case .broken:
                return .broken
            }
        }
        backlogStart += backlog.count
        backlog.removeAll(keepingCapacity: true)
        backlogHead = 0
        foldInto.removeAll(keepingCapacity: true)
        return .drained
    }

    // MARK: The ring

    private enum Put { case written, full, broken }

    private func put(_ frame: ChromiumHostFrame) -> Put {
        if tail &- head >= Self.capacity {
            head = headSlot.load(ordering: .acquiring)
            let used = tail &- head
            if used > Self.capacity {
                isBroken = true
                return .broken
            }
            if used == Self.capacity { return .full }
        }
        // SAFETY: slot `tail % capacity` of the frames area: framesOffset + capacity * frameSize == ringBytes, the
        // mapping's size, and the reader does not read the slot until the tail store below publishes it.
        unsafe Self.encode(frame, into: mapping.base + Self.framesOffset + Int(tail & (Self.capacity - 1)) * Self.frameSize)
        tail &+= 1
        tailSlot.store(tail, ordering: .sequentiallyConsistent)
        stats.written += 1
        // Dekker with the reader's park (store parked, then load the tail):
        // one side sees the other's store, so a parked reader always gets a ring.
        if parkedSlot.load(ordering: .sequentiallyConsistent) != 0,
           parkedSlot.exchange(0, ordering: .sequentiallyConsistent) != 0 {
            ring()
        }
        return .written
    }

    private func ring() {
        guard let doorbell else {
            ringWhenAttached = true
            return
        }
        stats.doorbells += 1
        // A dead port is a host that ended: its exit reaches the supervisor.
        _ = doorbell.ring()
    }

    // MARK: The backlog

    /// Keys, clicks and every other kind always wait; a move or wheel tick
    /// folds into its page's waiting one, else waits while fewer than
    /// ``coalescableLimit`` do, else is dropped and counted.
    private func spill(_ frame: ChromiumHostFrame) -> Push {
        let page = Self.browser(of: frame)
        guard Self.isCoalescable(frame) else {
            foldInto[page] = nil
            backlog.append(frame)
            stats.spilled += 1
            return .spilled
        }
        if let position = foldInto[page], position >= backlogStart + backlogHead,
           Self.coalesce(&backlog[position - backlogStart], frame) {
            stats.coalesced += 1
            return .spilled
        }
        guard coalescableWaiting < Self.coalescableLimit else {
            stats.dropped += 1
            return .dropped
        }
        foldInto[page] = backlogStart + backlog.count
        backlog.append(frame)
        coalescableWaiting += 1
        stats.spilled += 1
        return .spilled
    }

    /// Drops the frames that left the front of the backlog once there are
    /// enough of them, so a backlog that never fully drains does not grow.
    private func compactBacklog() {
        guard backlogHead >= Self.compactAfter, backlogHead * 2 >= backlog.count else { return }
        backlog.removeFirst(backlogHead)
        backlogStart += backlogHead
        backlogHead = 0
    }

    /// A pointer move (mouse phase 0) or a wheel tick: a newer one may fold into it.
    private static func isCoalescable(_ frame: ChromiumHostFrame) -> Bool {
        (frame.rawKind == ChromiumHostFrame.Kind.mouse.rawValue && frame.v[2] == 0)
            || frame.rawKind == ChromiumHostFrame.Kind.wheel.rawValue
    }

    /// Folds `next` into `waiting` when it only updates it: the host's
    /// `FrameQueue::Coalesce` (chromium_host_wire.h), for one page.
    private static func coalesce(_ waiting: inout ChromiumHostFrame, _ next: ChromiumHostFrame) -> Bool {
        guard waiting.rawKind == next.rawKind, waiting.flags == next.flags,
              browser(of: waiting) == browser(of: next) else { return false }
        if next.rawKind == ChromiumHostFrame.Kind.mouse.rawValue {
            // Moves only (phase 0), with the same buttons held.
            guard waiting.v[2] == 0, next.v[2] == 0, waiting.v[5] == next.v[5] else { return false }
            waiting = next  // the newest position, time and seq
            return true
        }
        if next.rawKind == ChromiumHostFrame.Kind.wheel.rawValue {
            // One phase and momentum phase only, as Blink's
            // WebMouseWheelEvent::CanCoalesce: a gesture's edges reach Chromium.
            guard waiting.v[4] == next.v[4], waiting.v[5] == next.v[5] else { return false }
            let dx = waiting.v[2], dy = waiting.v[3]
            waiting = next  // the newest position, time and seq; the summed deltas
            waiting.v[2] = saturatingAdd(dx, next.v[2])
            waiting.v[3] = saturatingAdd(dy, next.v[3])
            return true
        }
        return false
    }

    private static func saturatingAdd(_ a: Int32, _ b: Int32) -> Int32 {
        Int32(clamping: Int64(a) + Int64(b))
    }

    // MARK: Layout

    /// The ring's header (magic, version, capacity, frame size) at `base`, which must hold 16 readable bytes.
    nonisolated static func isRing(_ base: UnsafeRawPointer) -> Bool {
        // SAFETY: the four reads end at byte 16, which the caller's contract covers.
        unsafe UInt32(littleEndian: base.loadUnaligned(fromByteOffset: 0, as: UInt32.self)) == magic
            && UInt32(littleEndian: base.loadUnaligned(fromByteOffset: 4, as: UInt32.self)) == version
            && UInt32(littleEndian: base.loadUnaligned(fromByteOffset: 8, as: UInt32.self)) == UInt32(capacity)
            && UInt32(littleEndian: base.loadUnaligned(fromByteOffset: 12, as: UInt32.self)) == UInt32(frameSize)
    }

    /// Writes the ring's header into a zeroed region (``ChromiumHostInputRingRegion/make()``), which must hold
    /// `framesOffset` writable bytes.
    nonisolated static func format(_ base: UnsafeMutableRawPointer) {
        // SAFETY: every write ends inside the first `framesOffset` bytes, which the caller's contract covers.
        unsafe base.initializeMemory(as: UInt8.self, repeating: 0, count: framesOffset)
        unsafe base.storeBytes(of: magic.littleEndian, toByteOffset: 0, as: UInt32.self)
        unsafe base.storeBytes(of: version.littleEndian, toByteOffset: 4, as: UInt32.self)
        unsafe base.storeBytes(of: UInt32(capacity).littleEndian, toByteOffset: 8, as: UInt32.self)
        unsafe base.storeBytes(of: UInt32(frameSize).littleEndian, toByteOffset: 12, as: UInt32.self)
    }

    /// `frame`'s 64 header bytes as `chromium_host_wire.h`'s `Encode` writes
    /// them, with no payload, straight into `slot` (64-byte aligned, `frameSize` == 64 writable bytes).
    nonisolated static func encode(_ frame: ChromiumHostFrame, into slot: UnsafeMutableRawPointer) {
        // SAFETY (this function): every write ends by byte 64, the slot's size in the caller's contract, at an
        // offset aligned for its type (the slot is 64-byte aligned).
        unsafe slot.storeBytes(of: frame.rawKind.littleEndian, toByteOffset: 0, as: UInt32.self)
        unsafe slot.storeBytes(of: UInt32(0), toByteOffset: 4, as: UInt32.self)
        for index in 0..<6 {
            let value = index < frame.v.count ? frame.v[index] : 0
            unsafe slot.storeBytes(of: UInt32(bitPattern: value).littleEndian, toByteOffset: 8 + 4 * index, as: UInt32.self)
        }
        unsafe slot.storeBytes(of: frame.flags.littleEndian, toByteOffset: 32, as: UInt64.self)
        unsafe slot.storeBytes(of: frame.t0.littleEndian, toByteOffset: 40, as: UInt64.self)
        unsafe slot.storeBytes(of: frame.t1.littleEndian, toByteOffset: 48, as: UInt64.self)
        unsafe slot.storeBytes(of: frame.ch.littleEndian, toByteOffset: 56, as: UInt16.self)
        unsafe slot.storeBytes(of: frame.unmod.littleEndian, toByteOffset: 58, as: UInt16.self)
        unsafe slot.storeBytes(of: frame.seq.littleEndian, toByteOffset: 60, as: UInt32.self)
    }

    /// The client browser id a ring frame is for (`BrowserOf`): the low 32 bits of `t1`.
    nonisolated static func browser(of frame: ChromiumHostFrame) -> Int32 {
        Int32(bitPattern: UInt32(truncatingIfNeeded: frame.t1))
    }

    /// The ring's mapping in this process, `ringBytes` long (the region holds at least that many); unmapped
    /// once when the writer goes.
    @safe
    private nonisolated final class Mapping {
        let base: UnsafeMutableRawPointer

        init(fd: Int32) throws(ChromiumHostInputRingError) {
            var info = stat()
            // SAFETY: fstat writes one `stat` into `info` during the call.
            guard unsafe fstat(fd, &info) == 0, info.st_size >= off_t(ChromiumHostInputRing.ringBytes) else { throw .notARing }
            // SAFETY: maps `ringBytes` of a region at least that long (above); deinit unmaps it once.
            guard let base = unsafe mmap(nil, ChromiumHostInputRing.ringBytes, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0),
                  unsafe base != UnsafeMutableRawPointer(bitPattern: -1) else { throw .map(errno) }
            unsafe self.base = base
        }

        /// The atomic word at `offset`, one of the header's 8-byte aligned cursor offsets.
        func slot(_ offset: Int) -> AtomicPointerSlot {
            // SAFETY: `offset` is a header cursor, 8-byte aligned inside the mapping; the ring keeps this mapping
            // (and so the word) alive as long as it holds the slot.
            unsafe AtomicPointerSlot((base + offset).assumingMemoryBound(to: UInt64.self))
        }

        // SAFETY: the mapping made in init, unmapped once; no slot outlives the ring that holds this.
        deinit { unsafe munmap(base, ChromiumHostInputRing.ringBytes) }
    }
}
#endif
