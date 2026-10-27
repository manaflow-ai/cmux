#if DEBUG || CMUX_BENCH_HOOKS
// The Chromium host app ships in Debug builds only (embed-cef.sh), and so does its Swift side.
import Darwin

/// Frames the control socket has not taken yet, oldest first: the writer's
/// queue of Mojo's ChannelPosix (`mojo/core/channel_posix.cc`: write at once
/// when nothing waits, else queue and write when the socket takes more), and
/// `Outbox` in `chromium_host_control.h`.
///
/// A waiting state op (geometry, focus, visibility, screen info of one page)
/// is replaced by a newer one with the same key, which goes to the tail, so a
/// host that stops reading holds at most one waiting per page, plus the one in
/// flight when the socket took part of it (a partly written front frame keeps
/// its place). Keys, clicks and every other message wait in order and are
/// never dropped. One flush pass is one `sendmsg` for a batch of frames, as
/// `ChannelPosix::WriteOutgoingMessagesWithWritev` batches messages without
/// handles: a frame with descriptors starts a batch, since they go with its
/// first byte. Owns the duplicated descriptors of its entries.
nonisolated struct ChromiumHostControlOutbox: Sendable {
    struct Entry: Sendable {
        var bytes: [UInt8]
        var fds: [Int32]
        /// Bytes already written; the descriptors go with byte 0.
        var offset = 0
        var key: UInt64?
        /// False: replaced by a newer state op.
        var live = true
        /// Payload bytes in shared regions among ``fds`` (task 020): they
        /// count toward the quota, as inline bytes do.
        var sharedBytes = 0
    }

    /// What one `sendmsg` did.
    enum SendOutcome: Equatable, Sendable {
        case wrote(Int)
        case wouldBlock
        case interrupted
        /// The host closed its end (`EPIPE`, `ECONNRESET`).
        case peerClosed
        case failed
    }

    enum FlushResult: Equatable, Sendable {
        case drained
        /// The socket is full: the rest waits for it to take more.
        case blocked
        case peerClosed
        case failed
    }

    /// The most bytes one pass copies to batch small frames; a larger front
    /// frame goes alone, from its own bytes.
    static let batchBytes = 16 * 1024

    let quotaBytes: Int
    let quotaMessages: Int
    private var entries: [Entry] = []
    /// Entries before `head` are written; their slots are empty.
    private var head = 0
    /// The live entry of each state key: its index in `entries`.
    private var keyed: [UInt64: Int] = [:]
    private(set) var messages = 0
    private(set) var bytes = 0
    private var dead = 0
    /// The batch of one flush pass; its capacity is kept.
    private var scratch: [UInt8] = []

    init(quotaBytes: Int, quotaMessages: Int) {
        self.quotaBytes = quotaBytes
        self.quotaMessages = quotaMessages
    }

    var isEmpty: Bool { messages == 0 }
    var isOverQuota: Bool { bytes > quotaBytes || messages > quotaMessages }

    /// Waiting entries with `key` (0 or 1): live and not started. A partly
    /// written one is in flight, not waiting.
    func count(key: UInt64) -> Int {
        entries[head...].count(where: { $0.live && $0.key == key && $0.offset == 0 })
    }

    /// Queues a frame; true when it replaced a waiting entry with the same key.
    @discardableResult
    mutating func push(_ frame: [UInt8], fds: [Int32], key: UInt64?, sharedBytes: Int = 0) -> Bool {
        var replaced = false
        if let key, let index = keyed.removeValue(forKey: key), entries[index].offset == 0 {
            drop(at: index)
            replaced = true
        }
        bytes += frame.count + sharedBytes
        messages += 1
        entries.append(Entry(bytes: frame, fds: fds, key: key, sharedBytes: sharedBytes))
        if let key { keyed[key] = entries.count - 1 }
        if dead > 64, dead > messages { compact() }
        return replaced
    }

    /// Writes entries front to back while `send` takes them, one call per
    /// batch: the unwritten bytes of the front entry, then whole entries after
    /// it up to the next one with descriptors or ``batchBytes``. `send` gets
    /// the front entry's descriptors when the batch starts at its first byte.
    /// `send` gets a view of the outbox's own bytes, valid only during its call.
    @safe
    mutating func flush(_ send: (UnsafeRawBufferPointer, [Int32]) -> SendOutcome) -> FlushResult {
        while let index = frontIndex() {
            let (outcome, offered) = unsafe sendBatch(from: index, send)
            switch outcome {
            case .interrupted:
                continue
            case .wouldBlock:
                return .blocked
            case .peerClosed:
                return .peerClosed
            case .failed:
                return .failed
            case .wrote(let count):
                advance(by: count)
                if count < offered { return .blocked }
            }
        }
        return .drained
    }

    /// Drops every entry and closes its descriptors.
    mutating func removeAll() {
        for index in entries.indices { Self.closeFds(&entries[index]) }
        entries = []
        keyed = [:]
        head = 0
        dead = 0
        messages = 0
        bytes = 0
    }

    /// One `send` of the batch that starts at the front entry `index`, and
    /// how many bytes it offered.
    private mutating func sendBatch(from index: Int,
                                    _ send: (UnsafeRawBufferPointer, [Int32]) -> SendOutcome) -> (SendOutcome, Int) {
        let offset = entries[index].offset
        let fds = offset == 0 ? entries[index].fds : []
        let front = entries[index].bytes.count - offset
        var total = front
        var end = index + 1
        while end < entries.count {
            if entries[end].live {
                guard entries[end].fds.isEmpty, total + entries[end].bytes.count <= Self.batchBytes else { break }
                total += entries[end].bytes.count
            }
            end += 1
        }
        if total == front {
            // SAFETY: a view of the front entry's unsent bytes, inside its array, valid for the call.
            let outcome = unsafe entries[index].bytes.withUnsafeBytes { raw in
                unsafe send(UnsafeRawBufferPointer(rebasing: raw[offset...]), fds)
            }
            return (outcome, total)
        }
        scratch.removeAll(keepingCapacity: true)
        scratch.append(contentsOf: entries[index].bytes[offset...])
        for later in (index + 1)..<end where entries[later].live {
            scratch.append(contentsOf: entries[later].bytes)
        }
        // SAFETY: a view of the whole scratch array, valid for the call.
        return (unsafe scratch.withUnsafeBytes { unsafe send($0, fds) }, total)
    }

    /// Marks `count` bytes from the front written: whole entries leave, and a
    /// started entry's descriptors close (they went with its first byte).
    private mutating func advance(by count: Int) {
        var left = count
        while left > 0, let index = frontIndex() {
            if entries[index].offset == 0 { Self.closeFds(&entries[index]) }
            let remaining = entries[index].bytes.count - entries[index].offset
            guard left >= remaining else {
                entries[index].offset += left
                return
            }
            left -= remaining
            popFront(index)
        }
    }

    private mutating func frontIndex() -> Int? {
        while head < entries.count, !entries[head].live {
            entries[head] = Entry(bytes: [], fds: [])
            head += 1
            dead -= 1
        }
        return head < entries.count ? head : nil
    }

    private mutating func popFront(_ index: Int) {
        if let key = entries[index].key, keyed[key] == index { keyed[key] = nil }
        bytes -= entries[index].bytes.count + entries[index].sharedBytes
        messages -= 1
        entries[index] = Entry(bytes: [], fds: [])
        head += 1
        if head > 64, head * 2 > entries.count { compact() }
    }

    private mutating func drop(at index: Int) {
        Self.closeFds(&entries[index])
        bytes -= entries[index].bytes.count + entries[index].sharedBytes
        entries[index].bytes = []
        entries[index].live = false
        messages -= 1
        dead += 1
    }

    /// Removes written and replaced slots; O(entries), at most once per as many pushes or pops.
    private mutating func compact() {
        entries = entries[head...].filter(\.live)
        head = 0
        dead = 0
        keyed = [:]
        for (index, entry) in entries.enumerated() {
            if let key = entry.key { keyed[key] = index }
        }
    }

    private static func closeFds(_ entry: inout Entry) {
        for fd in entry.fds { Darwin.close(fd) }
        entry.fds = []
    }
}
#endif
