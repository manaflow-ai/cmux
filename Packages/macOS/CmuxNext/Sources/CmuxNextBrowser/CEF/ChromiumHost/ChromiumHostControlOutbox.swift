#if DEBUG
// The Chromium host app ships in Debug builds only (embed-cef.sh), and so does its Swift side.
import Darwin

/// Frames the control socket has not taken yet, oldest first: the writer's
/// queue of Mojo's ChannelPosix (`mojo/core/channel_posix.cc`: write at once
/// when nothing waits, else queue and write when the socket takes more), and
/// `Outbox` in `chromium_host_control.h`.
///
/// A waiting state op (geometry, focus, visibility, screen info of one page)
/// is replaced by a newer one with the same key, which goes to the tail, so a
/// host that stops reading holds at most one per page. Keys, clicks and every
/// other message wait in order and are never dropped. A partly written front
/// frame keeps its place. Owns the duplicated descriptors of its entries.
nonisolated struct ChromiumHostControlOutbox: Sendable {
    struct Entry: Sendable {
        var bytes: [UInt8]
        var fds: [Int32]
        /// Bytes already written; the descriptors go with byte 0.
        var offset = 0
        var key: UInt64?
        /// False: replaced by a newer state op.
        var live = true
    }

    /// What one `sendmsg` did.
    enum SendOutcome: Equatable, Sendable {
        case wrote(Int)
        case wouldBlock
        case interrupted
        case failed
    }

    enum FlushResult: Equatable, Sendable {
        case drained
        /// The socket is full: the rest waits for it to take more.
        case blocked
        case failed
    }

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

    init(quotaBytes: Int, quotaMessages: Int) {
        self.quotaBytes = quotaBytes
        self.quotaMessages = quotaMessages
    }

    var isEmpty: Bool { messages == 0 }
    var isOverQuota: Bool { bytes > quotaBytes || messages > quotaMessages }

    /// Live entries with `key` (0 or 1).
    func count(key: UInt64) -> Int {
        entries[head...].count(where: { $0.live && $0.key == key })
    }

    /// Queues a frame; true when it replaced a waiting entry with the same key.
    @discardableResult
    mutating func push(_ frame: [UInt8], fds: [Int32], key: UInt64?) -> Bool {
        var replaced = false
        if let key, let index = keyed.removeValue(forKey: key), entries[index].offset == 0 {
            drop(at: index)
            replaced = true
        }
        bytes += frame.count
        messages += 1
        entries.append(Entry(bytes: frame, fds: fds, key: key))
        if let key { keyed[key] = entries.count - 1 }
        if dead > 64, dead > messages { compact() }
        return replaced
    }

    /// Writes entries front to back while `send` takes them. `send` gets the
    /// unwritten bytes of the front entry and, for its first byte, its descriptors.
    mutating func flush(_ send: (UnsafeRawBufferPointer, [Int32]) -> SendOutcome) -> FlushResult {
        while let index = frontIndex() {
            let offset = entries[index].offset
            let fds = offset == 0 ? entries[index].fds : []
            let outcome = entries[index].bytes.withUnsafeBytes { raw in
                send(UnsafeRawBufferPointer(rebasing: raw[offset...]), fds)
            }
            switch outcome {
            case .interrupted:
                continue
            case .wouldBlock:
                return .blocked
            case .failed:
                return .failed
            case .wrote(let count):
                if offset == 0 { Self.closeFds(&entries[index]) }  // they went with the first byte
                entries[index].offset += count
                if entries[index].offset < entries[index].bytes.count { return .blocked }
                popFront(index)
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
        bytes -= entries[index].bytes.count
        messages -= 1
        entries[index] = Entry(bytes: [], fds: [])
        head += 1
        if head > 64, head * 2 > entries.count { compact() }
    }

    private mutating func drop(at index: Int) {
        Self.closeFds(&entries[index])
        bytes -= entries[index].bytes.count
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
