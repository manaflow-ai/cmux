/// The typed name of a request the app sends the cmux-tui daemon: the `cmd` it writes on the wire and the method
/// id the daemon's own `daemon.request` slice carries for it (cmux-tui-core/src/server/request_spans.rs,
/// `RequestMethod`), so a trace record names a request with a number and never interns a runtime string
/// (Chrome's trace events take only static names, base/trace_event/trace_event.h).
///
/// A request type declares its name once, as a `StaticString` literal (``DaemonRequest/commandName``); the id is
/// looked up when that static is first read, never per request. The tables are generated from the daemon's:
/// `Command` rows (command_names.rs) and the routed prefixes in DaemonCommandName+Commands.swift, v2 resource
/// operations in DaemonCommandName+Resources.swift, by scripts/cmux-next/gen-daemon-command-names.py. A name
/// neither table has gets the id the daemon gives it: `ROUTED_BASE` plus its prefix's class (`agent-`,
/// `access-request`: agent; `browser-`: browser), else other.
///
/// ```swift
/// public static let commandName: DaemonCommandName = "identify"  // id 0, the row of `Identify` in `COMMANDS`
/// ```
public struct DaemonCommandName: Sendable, Equatable, ExpressibleByStringLiteral, CustomStringConvertible {
    public typealias StringLiteralType = StaticString
    public typealias ExtendedGraphemeClusterLiteralType = StaticString
    public typealias UnicodeScalarLiteralType = StaticString

    /// The daemon's method id: a `Command`'s row in `COMMANDS`, `RESOURCE_BASE` plus a resource operation's
    /// index, or `ROUTED_BASE` plus a class.
    public let id: UInt16
    /// The `cmd` (or v2 `operation`) the request writes on the wire.
    public let wire: String

    /// request_spans.rs `RequestMethod::RESOURCE_BASE`: the first v2 resource operation's id.
    static let resourceBase: UInt16 = 0x4000

    /// The name spelled `value`, with the daemon's id for it. Read once per request type (a `static let`).
    public init(stringLiteral value: StaticString) {
        wire = value.description
        id = Self.lookup(wire)
    }

    /// A name spelled at run time (the v2 resource envelope's `operation`, a test's command): the same lookup
    /// as a literal, on every call.
    public init(wire: String) {
        self.wire = wire
        id = Self.lookup(wire)
    }

    /// The wire spelling, as logs and errors name the request.
    public var description: String { wire }

    /// The daemon's method id of `wire`. One hash of the bytes, one integer `switch` per table and one byte
    /// compare; a name no table spells takes the routed id. No dictionary, lock or allocation.
    static func lookup(_ wire: String) -> UInt16 {
        let hash = Self.hash(wire)
        guard let row = Self.command(hash: hash) ?? Self.resource(hash: hash), Self.spells(row.text, wire) else {
            return Self.routedID(wire)
        }
        return row.id
    }

    /// 64-bit FNV-1a over the UTF-8 bytes of `text` (the generator's `fnv1a`).
    static func hash(_ text: String) -> UInt64 {
        var value: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in text.utf8 { value = (value ^ UInt64(truncatingIfNeeded: byte)) &* 0x0000_0100_0000_01B3 }
        return value
    }

    /// Whether `wire` is `text`, byte for byte (a hash match alone may be another string).
    static func spells(_ text: StaticString, _ wire: String) -> Bool {
        // SAFETY: the buffer is the literal's own UTF-8 bytes, static for the program's life; it is only read,
        // inside the closure, and its count bounds the comparison.
        unsafe text.withUTF8Buffer { unsafe wire.utf8.elementsEqual($0) }
    }
}
