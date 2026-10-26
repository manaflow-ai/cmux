#if DEBUG || CMUX_BENCH_HOOKS
// The Chromium host app ships in Debug builds only (embed-cef.sh), and so does its Swift side.
import CmuxNextCompat
import Darwin

/// cmux's writer of the input ring to the Chromium Host
/// (plans/cmux-next/chrome-parity/p01-process.md 3.1, task p01-process-041).
///
/// Keys, clicks, pointer moves and wheel ticks go to the host through 4,096
/// frames of 64 bytes in a shared memory region, not the control socket. One
/// write stores the frame and release-stores the tail: no lock, no system call,
/// unless the host's reader is parked, when it also sends one Mach message
/// with a zero timeout (``ChromiumHostInputDoorbell``; a Mach message carries
/// this thread's QoS to the reader, a pipe byte would not, as Mojo on macOS
/// uses Mach ports in mojo/core/channel_mac.cc). The layout, the park protocol
/// and the host's reader are `ChromiumHost/src/chromium_host_input_ring.h`;
/// both sides check the same golden bytes (`ChromiumHostInputRingTests`,
/// `chromium_host_input_ring_test.cpp`).
///
/// A full ring (a host whose UI thread stopped) never makes a write wait: the
/// frame goes to this writer's backlog, which the next write or
/// ``flushBacklog()`` moves into the ring first, so the host still gets every
/// frame in order. In the backlog a pointer move replaces a waiting move of
/// the same page and wheel deltas add up into a waiting wheel tick, as the
/// host's `FrameQueue` coalesces; keys and clicks are kept. Over
/// ``backlogLimit`` waiting frames a write is refused and counted, as the
/// control channel's quota counts.
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
    /// Frames the backlog holds after coalescing before a write is refused.
    nonisolated static let backlogLimit = 4_096

    /// What one ``write(_:browser:)`` did.
    nonisolated enum Push: Equatable, Sendable {
        /// In the ring.
        case written
        /// In the backlog: the ring is full.
        case spilled
        /// Dropped and counted: a frame with a payload (ring frames have
        /// none), or a full backlog.
        case refused
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
    private var backlog: [ChromiumHostFrame] = []
    private var backlogHead = 0

    /// Maps the ring in `fd` (``ChromiumHostInputRingRegion/fd``; the caller
    /// keeps and closes the descriptor). Rings `doorbell` when the reader
    /// parked; nil until ``attach(_:)``.
    init(region fd: Int32, doorbell: (any ChromiumHostInputDoorbell)?) throws(ChromiumHostInputRingError) {
        let mapping = try Mapping(fd: fd)
        guard Self.isRing(UnsafeRawPointer(mapping.base)) else { throw .notARing }
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
    func write(_ frame: ChromiumHostFrame, browser: Int32) -> Push { // perf-hot: 1us cef-host-input-ring (every key, click, move and wheel to the Chromium Host)
        guard !isBroken else { return .broken }
        guard frame.payload.isEmpty else {
            stats.refused += 1
            return .refused
        }
        var stamped = frame
        stamped.seq = nextSeq
        nextSeq &+= 1
        stamped.t1 = (frame.t1 & 0xffff_ffff_0000_0000) | UInt64(UInt32(bitPattern: browser))
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
            case .written: backlogHead += 1
            case .full: return .waiting(backlogCount)
            case .broken: return .broken
            }
        }
        backlog.removeAll(keepingCapacity: true)
        backlogHead = 0
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
        Self.encode(frame, into: mapping.base + Self.framesOffset + Int(tail & (Self.capacity - 1)) * Self.frameSize)
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

    private func spill(_ frame: ChromiumHostFrame) -> Push {
        if backlogCount > 0, Self.coalesce(&backlog[backlog.count - 1], frame) {
            stats.coalesced += 1
            return .spilled
        }
        guard backlogCount < Self.backlogLimit else {
            stats.refused += 1
            return .refused
        }
        backlog.append(frame)
        stats.spilled += 1
        return .spilled
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

    /// The ring's header (magic, version, capacity, frame size) at `base`.
    nonisolated static func isRing(_ base: UnsafeRawPointer) -> Bool {
        UInt32(littleEndian: base.loadUnaligned(fromByteOffset: 0, as: UInt32.self)) == magic
            && UInt32(littleEndian: base.loadUnaligned(fromByteOffset: 4, as: UInt32.self)) == version
            && UInt32(littleEndian: base.loadUnaligned(fromByteOffset: 8, as: UInt32.self)) == UInt32(capacity)
            && UInt32(littleEndian: base.loadUnaligned(fromByteOffset: 12, as: UInt32.self)) == UInt32(frameSize)
    }

    /// Writes the ring's header into a zeroed region (``ChromiumHostInputRingRegion/make()``).
    nonisolated static func format(_ base: UnsafeMutableRawPointer) {
        base.initializeMemory(as: UInt8.self, repeating: 0, count: framesOffset)
        base.storeBytes(of: magic.littleEndian, toByteOffset: 0, as: UInt32.self)
        base.storeBytes(of: version.littleEndian, toByteOffset: 4, as: UInt32.self)
        base.storeBytes(of: UInt32(capacity).littleEndian, toByteOffset: 8, as: UInt32.self)
        base.storeBytes(of: UInt32(frameSize).littleEndian, toByteOffset: 12, as: UInt32.self)
    }

    /// `frame`'s 64 header bytes as `chromium_host_wire.h`'s `Encode` writes
    /// them, with no payload, straight into `slot` (64-byte aligned).
    nonisolated static func encode(_ frame: ChromiumHostFrame, into slot: UnsafeMutableRawPointer) {
        slot.storeBytes(of: frame.rawKind.littleEndian, toByteOffset: 0, as: UInt32.self)
        slot.storeBytes(of: UInt32(0), toByteOffset: 4, as: UInt32.self)
        for index in 0..<6 {
            let value = index < frame.v.count ? frame.v[index] : 0
            slot.storeBytes(of: UInt32(bitPattern: value).littleEndian, toByteOffset: 8 + 4 * index, as: UInt32.self)
        }
        slot.storeBytes(of: frame.flags.littleEndian, toByteOffset: 32, as: UInt64.self)
        slot.storeBytes(of: frame.t0.littleEndian, toByteOffset: 40, as: UInt64.self)
        slot.storeBytes(of: frame.t1.littleEndian, toByteOffset: 48, as: UInt64.self)
        slot.storeBytes(of: frame.ch.littleEndian, toByteOffset: 56, as: UInt16.self)
        slot.storeBytes(of: frame.unmod.littleEndian, toByteOffset: 58, as: UInt16.self)
        slot.storeBytes(of: frame.seq.littleEndian, toByteOffset: 60, as: UInt32.self)
    }

    /// The client browser id a ring frame is for (`BrowserOf`): the low 32 bits of `t1`.
    nonisolated static func browser(of frame: ChromiumHostFrame) -> Int32 {
        Int32(bitPattern: UInt32(truncatingIfNeeded: frame.t1))
    }

    /// The ring's mapping in this process; unmapped when the writer goes.
    private nonisolated final class Mapping {
        let base: UnsafeMutableRawPointer

        init(fd: Int32) throws(ChromiumHostInputRingError) {
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_size >= off_t(ChromiumHostInputRing.ringBytes) else { throw .notARing }
            guard let base = mmap(nil, ChromiumHostInputRing.ringBytes, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0),
                  base != UnsafeMutableRawPointer(bitPattern: -1) else { throw .map(errno) }
            self.base = base
        }

        func slot(_ offset: Int) -> AtomicPointerSlot {
            AtomicPointerSlot((base + offset).assumingMemoryBound(to: UInt64.self))
        }

        deinit { munmap(base, ChromiumHostInputRing.ringBytes) }
    }
}
#endif
