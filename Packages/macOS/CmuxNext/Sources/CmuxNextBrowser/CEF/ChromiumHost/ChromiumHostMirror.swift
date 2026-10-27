#if DEBUG || CMUX_BENCH_HOOKS
// The Chromium host app ships in Debug builds only (embed-cef.sh), and so does its Swift side.

/// The main-thread cache of one Chromium host connection's `mirror` values
/// (plans/cmux-next/chrome-parity/p01-process.md 3.2, task 016b), the Swift
/// twin of `ChromiumHost/client/remote_shim_mirror.h`: the same frames and
/// rules. Chrome answers NSTextInputClient queries the same way, from the
/// TextInputState the renderer pushed
/// (`content/browser/renderer_host/text_input_manager.cc`).
///
/// - Each ``ChromiumHostControlChannel`` owns one (``ChromiumHostControlChannel/mirror``):
///   its values, marks and tokens are that connection's, so a new host gets
///   a new mirror and an old channel's end never touches it.
/// - The channel applies MIRROR and ACK frames here on main, in arrival order
///   with the events of the same per-frame batch (``ChromiumHostControlBatch``),
///   so an event's handler reads the values the host pushed before it.
/// - Read your writes: ``ChromiumHostControlChannel/post(_:)`` marks the keys
///   its op changes (the generated ``ChromiumHostOp/pendingKeys``) as pending
///   under its token. Until the host's ACK of that token, ``read(_:key:)``
///   returns the optimistic value when there is one, else ``Read/pending``,
///   never the value from before the post. The host pushes those keys again
///   after it runs the op and before the ACK (`HostContext::RefreshMirror`),
///   so the value read once the ACK clears the mark is the host's after the op.
/// - Main actor only: no lock on any path.
@MainActor
final class ChromiumHostMirror {
    typealias Field = ChromiumHostControlMessage.Field

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

    /// One mirror key a post changes, with the post's values filled in.
    nonisolated struct PendingKey: Equatable, Sendable {
        var mirror: ChromiumHostOp
        /// The key's fields in order; nil is `*` (any value).
        var parameters: [Field?]
        /// What the key reads until the ACK; nil reads ``Read/pending``.
        var optimistic: [Field]?

        init(mirror: ChromiumHostOp, parameters: [Field?], optimistic: [Field]? = nil) {
            self.mirror = mirror
            self.parameters = parameters
            self.optimistic = optimistic
        }

        func matches(_ key: [Field]) -> Bool {
            parameters.count == key.count && zip(parameters, key).allSatisfy { $0 == nil || $0 == $1 }
        }

        /// The keys `message` changes: its op's generated `pending_keys`, each
        /// named parameter taken from the frame field the client encodes it
        /// in. Empty for an op without them; nil when the frame lacks a field.
        static func changed(by message: ChromiumHostControlMessage) -> [PendingKey]? {
            guard !message.isReply, let op = ChromiumHostOp(rawValue: message.op) else { return [] }
            var keys: [PendingKey] = []
            for key in op.pendingKeys {
                var parameters: [Field?] = []
                for index in key.fields {
                    guard let index else {
                        parameters.append(nil)
                        continue
                    }
                    guard message.fields.indices.contains(index) else { return nil }
                    parameters.append(message.fields[index])
                }
                keys.append(PendingKey(mirror: key.mirror, parameters: parameters))
            }
            return keys
        }

        /// Whether `message` is an op with `pending_keys`, which only
        /// ``ChromiumHostControlChannel/post(_:)`` sends.
        static func marks(_ message: ChromiumHostControlMessage) -> Bool {
            guard !message.isReply, let op = ChromiumHostOp(rawValue: message.op) else { return false }
            return !op.pendingKeys.isEmpty
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

    /// Made by its channel's core, off main; used on main only.
    nonisolated init() {}

    /// The value of mirror `op` for `key` (every parameter, in order). The
    /// newest pending post that matches decides until its ACK.
    func read(_ op: ChromiumHostOp, key: [Field]) -> Read {
        if let mark = marks[op.rawValue]?.last(where: { $0.key.matches(key) }) {
            return mark.key.optimistic.map(Read.optimistic) ?? .pending
        }
        return values[op.rawValue]?[Key(key)].map(Read.value) ?? .absent
    }

    /// Marks `keys` pending under `token` (non-zero) until its ACK.
    func markPending(token: UInt32, _ keys: [PendingKey]) {
        guard token != 0 else { return }  // no ACK would clear it
        for key in keys { marks[key.mirror.rawValue, default: []].append(Mark(token: token, key: key)) }
    }

    /// The post under `token` was not sent: no ACK comes for it.
    func dropPending(token: UInt32) {
        clear(token: token)
    }

    /// Whether `message` is a MIRROR or ACK frame, which ``apply(_:)`` takes.
    nonisolated static func takes(_ message: ChromiumHostControlMessage) -> Bool {
        message.op == ChromiumHostOp.mirrorOp || message.op == ChromiumHostOp.ackOp
    }

    /// Whether `reply` is the ACK of a post in `awaited`, which it leaves.
    nonisolated static func isAck(_ reply: ChromiumHostControlMessage, awaited: inout Set<UInt32>) -> Bool {
        reply.op == ChromiumHostOp.ackOp && awaited.remove(reply.token) != nil
    }

    /// Applies one MIRROR frame (`i32 mirror op | bytes key | bytes value`, the
    /// key and value each an `EncodeFields` body, no value to forget the key;
    /// HostContext::PushMirror and ForgetMirror) or ACK (a reply frame with
    /// the op's token). False when it is malformed: the connection ends.
    func apply(_ message: ChromiumHostControlMessage) -> Bool {
        if message.op == ChromiumHostOp.ackOp {
            guard message.isReply, message.token != 0, message.fields.isEmpty, message.fds.isEmpty else { return false }
            clear(token: message.token)
            return true
        }
        let fields = message.fields
        guard message.op == ChromiumHostOp.mirrorOp, !message.isReply, message.fds.isEmpty,
              fields.count == 2 || fields.count == 3,
              case .i32(let op) = fields[0].value, (1...Self.maxExportOp).contains(op),
              case .bytes(let keyBytes) = fields[1].value, let key = Self.decodeFields(keyBytes) else { return false }
        guard fields.count == 3 else {
            values[UInt16(op)]?[Key(key)] = nil
            return true
        }
        guard case .bytes(let valueBytes) = fields[2].value,
              let value = Self.decodeFields(valueBytes) else { return false }
        values[UInt16(op), default: [:]][Key(key)] = value
        return true
    }

    /// The fields of an `EncodeFields` body (`chromium_host_tlv.h`): a frame
    /// body, so it decodes as one behind a header with no op, flags or token.
    /// Nil when malformed, a shared field included (it needs a descriptor).
    nonisolated static func decodeFields(_ body: [UInt8]) -> [Field]? {
        guard body.count <= ChromiumHostControlMessage.maxBody else { return nil }
        var frame: [UInt8] = []
        frame.reserveCapacity(ChromiumHostControlMessage.headerSize + body.count)
        frame.appendLittleEndian(UInt32(body.count))
        frame.append(contentsOf: [UInt8](repeating: 0, count: ChromiumHostControlMessage.headerSize - 4))
        frame.append(contentsOf: body)
        var fds: [Int32] = []
        guard case .frame(let message, _) = ChromiumHostControlMessage.decode(frame[...], fds: &fds) else { return nil }
        return message.fields
    }

    /// The host is gone: its values and every pending mark go with it.
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

    /// A key's fields as a dictionary key: tag and value, as remote_shim_mirror.h
    /// keys by EncodeFields.
    private nonisolated struct Key: Hashable, Sendable {
        let fields: [Field]

        init(_ fields: [Field]) {
            self.fields = fields
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(fields.count)
            for field in fields {
                hasher.combine(field.tag)
                switch field.value {
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
