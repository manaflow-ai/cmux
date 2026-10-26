/// The typed name of a request the app sends the cmux-tui daemon: the method id the daemon's own
/// `daemon.request` slice carries (cmux-tui-core/src/server/request_spans.rs, `RequestMethod`) and its
/// spelling as a `StaticString`, so a trace record names a request with a number and never interns a
/// runtime string (Chrome's trace events take only static names, base/trace_event/trace_event.h).
///
/// The tables are generated from the daemon's: `Command` rows (command_names.rs) in
/// DaemonCommandName+Commands.swift and v2 resource operations in DaemonCommandName+Resources.swift,
/// by scripts/cmux-next/gen-daemon-command-names.py. A name neither table has is ``other``.
///
/// ```swift
/// DaemonCommandName(wire: "identify").id  // 0, the row of `Identify` in `COMMANDS`
/// ```
struct DaemonCommandName: Sendable, Equatable {
    /// The daemon's method id: a `Command`'s row in `COMMANDS`, ``resourceBase`` plus a resource operation's
    /// index, or ``other``'s.
    let id: UInt16
    /// The spelling the table lists (an alias keeps its own).
    let text: StaticString

    /// request_spans.rs `RequestMethod::RESOURCE_BASE`: the first v2 resource operation's id.
    static let resourceBase: UInt16 = 0x4000

    /// A name neither table has: request_spans.rs `ROUTED_BASE` plus `MethodClass::Other` (7), the id the
    /// daemon gives such a line.
    static let other = DaemonCommandName(id: 0x8007, text: "other")

    init(id: UInt16, text: StaticString) {
        self.id = id
        self.text = text
    }

    /// The name the daemon knows as `wire`, or ``other``. One hash of the bytes, one integer `switch` per
    /// table and one byte compare: no dictionary, lock or allocation.
    init(wire: String) {
        let hash = Self.hash(wire)
        guard let name = Self.command(hash: hash) ?? Self.resource(hash: hash), name.isSpelled(wire) else {
            self = .other
            return
        }
        self = name
    }

    /// 64-bit FNV-1a over the UTF-8 bytes of `text` (the generator's `fnv1a`).
    static func hash(_ text: String) -> UInt64 {
        var value: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in text.utf8 { value = (value ^ UInt64(truncatingIfNeeded: byte)) &* 0x0000_0100_0000_01B3 }
        return value
    }

    /// Whether `wire` is this name's spelling, byte for byte (a hash match alone may be another string).
    func isSpelled(_ wire: String) -> Bool {
        text.withUTF8Buffer { wire.utf8.elementsEqual($0) }
    }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
}
