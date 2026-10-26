#if DEBUG
// The Chromium host app ships in Debug builds only (embed-cef.sh), and so does its Swift side.

/// The main-thread cache of the Chromium host's `mirror` values
/// (plans/cmux-next/chrome-parity/p01-process.md 3.2, task 016b), the Swift
/// twin of `ChromiumHost/client/remote_shim_mirror.h`: the same frames and
/// rules. Chrome answers NSTextInputClient queries the same way, from the
/// TextInputState the renderer pushed
/// (`content/browser/renderer_host/text_input_manager.cc`).
///
/// - ``ChromiumHostControlChannel`` applies MIRROR and ACK frames here on
///   main, in arrival order with the events of the same per-frame batch, so an
///   event's handler reads the values the host pushed before it.
/// - Read your writes: ``ChromiumHostControlChannel/post(_:changing:)`` marks
///   the keys a post changes as pending under its token. Until the host's ACK
///   for that token, ``read(_:key:)`` returns the optimistic value when the
///   post gave one, else ``Read/pending``, never the value from before the post.
/// - Main actor only: no lock on any path.
@MainActor
final class ChromiumHostMirror {
    typealias Value = ChromiumHostControlMessage.Value
    typealias Field = ChromiumHostControlMessage.Field

    /// The generator's MIRROR and ACK op ids (gen-chromium-host-wire.py;
    /// scripts/cmux-next/tests/remote-shim-mirror.test.sh checks they agree).
    nonisolated static let mirrorOp: UInt16 = 0x8003
    nonisolated static let ackOp: UInt16 = 0x8004
    /// Op ids of exports are 1...N; host -> cmux ops start at 0x8000.
    nonisolated static let maxExportOp: Int32 = 0x7fff

    nonisolated enum Read: Equatable, Sendable {
        /// Nothing pushed for the key (before attach, or after the host ended).
        case absent
        /// A post changed the key and its ACK has not come.
        case pending
        /// A post changed the key to this value and its ACK has not come.
        case optimistic([Field])
        /// The value the host pushed last.
        case value([Field])

        /// The value to serve: the optimistic or pushed one.
        var fields: [Field]? {
            switch self {
            case .absent, .pending: nil
            case .optimistic(let fields), .value(let fields): fields
            }
        }
    }

    /// One mirror key a post changes (`pending_keys` in chromium-host-ops.json).
    nonisolated struct PendingKey: Equatable, Sendable {
        /// The mirror's op id.
        var mirror: UInt16
        /// The key's parameters in order; nil is `*` (any value).
        var parameters: [Value?]
        /// What the key reads until the ACK; nil reads ``Read/pending``.
        var optimistic: [Field]?

        init(mirror: UInt16, parameters: [Value?], optimistic: [Field]? = nil) {
            self.mirror = mirror
            self.parameters = parameters
            self.optimistic = optimistic
        }

        func matches(_ key: [Value]) -> Bool {
            parameters.count == key.count && zip(parameters, key).allSatisfy { $0 == nil || $0 == $1 }
        }
    }

    private nonisolated struct Mark: Sendable {
        let token: UInt32
        let key: PendingKey
    }

    /// mirror op -> key -> the value fields the host pushed last.
    private var values: [UInt16: [Key: [Field]]] = [:]
    /// mirror op -> pending marks, oldest first.
    private var marks: [UInt16: [Mark]] = [:]

    init() {}

    /// The value of mirror `op` for `key` (every parameter, in order). The
    /// newest pending post that matches decides until its ACK.
    func read(_ op: UInt16, key: [Value]) -> Read {
        if let mark = marks[op]?.last(where: { $0.key.matches(key) }) {
            return mark.key.optimistic.map(Read.optimistic) ?? .pending
        }
        return values[op]?[Key(key)].map(Read.value) ?? .absent
    }

    /// Marks `keys` pending under `token` (non-zero) until its ACK.
    func markPending(token: UInt32, _ keys: [PendingKey]) {
        guard token != 0 else { return }  // no ACK would clear it
        for key in keys { marks[key.mirror, default: []].append(Mark(token: token, key: key)) }
    }

    /// The post under `token` was not sent: no ACK comes for it.
    func dropPending(token: UInt32) {
        clear(token: token)
    }

    /// Whether `message` is a MIRROR or ACK frame, which ``apply(_:)`` takes.
    nonisolated static func takes(_ message: ChromiumHostControlMessage) -> Bool {
        message.op == mirrorOp || message.op == ackOp
    }

    /// Whether `reply` is the ACK of a post in `awaited`, which it leaves.
    nonisolated static func isAck(_ reply: ChromiumHostControlMessage, awaited: inout Set<UInt32>) -> Bool {
        reply.op == ackOp && awaited.remove(reply.token) != nil
    }

    /// Runs `batch` in arrival order: each MIRROR or ACK frame applies here
    /// before the messages after it, and each run of other messages goes to
    /// `onMessages`, so an event's handler reads the values the host pushed
    /// before that event (it pushes them first) and none pushed after. The
    /// index of a malformed MIRROR or ACK frame (nothing from it on ran), or nil.
    func deliver(_ batch: [ChromiumHostControlMessage],
                 to onMessages: @MainActor ([ChromiumHostControlMessage]) -> Void) -> Int? {
        var run: [ChromiumHostControlMessage] = []
        for (index, message) in batch.enumerated() {
            guard Self.takes(message) else {
                run.append(message)
                continue
            }
            if !run.isEmpty {
                onMessages(run)
                run = []
            }
            guard apply(message) else { return index }
        }
        if !run.isEmpty { onMessages(run) }
        return nil
    }

    /// Applies one MIRROR frame (`i32 mirror op | i32 key field count | key
    /// fields | value fields`, HostContext::PushMirror) or ACK (a reply frame
    /// with the op's token). False when it is malformed: the connection ends.
    func apply(_ message: ChromiumHostControlMessage) -> Bool {
        if message.op == Self.ackOp {
            guard message.isReply, message.token != 0, message.fields.isEmpty, message.fds.isEmpty else { return false }
            clear(token: message.token)
            return true
        }
        let fields = message.fields
        guard message.op == Self.mirrorOp, !message.isReply, message.fds.isEmpty, fields.count >= 2,
              fields[0].tag == 0, case .i32(let op) = fields[0].value, (1...Self.maxExportOp).contains(op),
              fields[1].tag == 0, case .i32(let keyCount) = fields[1].value,
              keyCount >= 0, Int(keyCount) <= fields.count - 2 else { return false }
        let keyEnd = 2 + Int(keyCount)
        values[UInt16(op), default: [:]][Key(fields[2..<keyEnd].map(\.value))] = Array(fields[keyEnd...])
        return true
    }

    /// The host is gone: its values and every pending mark go with it (the
    /// next host pushes its own at attach).
    func hostEnded() {
        values = [:]
        marks = [:]
    }

    /// Marks waiting for an ACK.
    var pendingCount: Int { marks.values.reduce(0) { $0 + $1.count } }

    private func clear(token: UInt32) {
        for op in Array(marks.keys) {
            marks[op]?.removeAll { $0.token == token }
            if marks[op]?.isEmpty == true { marks[op] = nil }
        }
    }

    /// A key's parameters as a dictionary key.
    private nonisolated struct Key: Hashable, Sendable {
        let parameters: [Value]

        init(_ parameters: [Value]) {
            self.parameters = parameters
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(parameters.count)
            for parameter in parameters {
                switch parameter {
                case .i32(let number):
                    hasher.combine(1)
                    hasher.combine(number)
                case .i64(let number):
                    hasher.combine(2)
                    hasher.combine(number)
                case .f64(let number):
                    hasher.combine(3)
                    hasher.combine(number)
                case .bytes(let bytes):
                    hasher.combine(4)
                    hasher.combine(bytes)
                case .str(let text):
                    hasher.combine(5)
                    hasher.combine(text)
                }
            }
        }
    }
}
#endif
