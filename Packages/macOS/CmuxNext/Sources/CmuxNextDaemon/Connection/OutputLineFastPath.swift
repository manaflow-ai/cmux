import Darwin
import Foundation

/// An attach `output` line split around its base64 `data`, so the reader thread never runs the JSON parser over
/// the terminal's bytes (CMUX-571 goal terminal-throughput).
///
/// The daemon writes an output line with its keys sorted (`serialize_snapshot_output` in cmux-tui-core's
/// render_service.rs, and serde_json's sorted maps for the rest): `{"data":"<base64>","event":"output",...}`, with
/// `colors` before `data` when the line carries colors. In a flood such a line is up to 1 MiB of terminal bytes,
/// about 1.4 MB of base64, and before this split the reader parsed all of it as JSON twice: once for the routing
/// envelope (``LineTransport`` `route`) and once for the event (``TerminalAttachment`` `decodeAttachLine`), and
/// then decoded the base64. Now both parse only the line's other members, a few dozen bytes, and the base64 is
/// decoded straight from the line.
///
/// Only a line that starts with `{"data":"` takes this path; any other line (one with `colors`, any reordering or
/// escaping) is parsed whole, as before, so the wire format is unchanged and a line this does not recognize costs
/// one prefix compare.
nonisolated struct OutputLineFastPath: Equatable {
    /// The base64 text of `data`, as offsets from the line's `startIndex`.
    let base64: Range<Int>
    /// The line's object without its `data` member: what the JSON parser reads.
    let rest: Data

    private static let prefix = Data(#"{"data":""#.utf8)

    /// The split of `line`, or nil when it is not an output line in the daemon's layout.
    static func split(_ line: Data) -> OutputLineFastPath? {
        guard line.starts(with: prefix) else { return nil }
        let start = prefix.count
        // Base64 has no quote or backslash, so the first quote ends the string (memchr: one pass at memory speed).
        let close: Int? = line.withUnsafeBytes { raw in
            guard let base = raw.baseAddress, raw.count > start,
                  let hit = memchr(base + start, 0x22, raw.count - start) else { return nil }
            let end = base.distance(to: UnsafeRawPointer(hit))
            return memchr(base + start, 0x5C, end - start) == nil ? end : nil
        }
        guard let close else { return nil }
        let after = line.dropFirst(close + 1)
        var rest = Data([0x7B])  // "{"
        switch after.first {
        case 0x2C:  // ",": the members after data (a trailing comma is not JSON: parsed whole, and refused there)
            let members = after.dropFirst()
            guard let next = members.first, next != 0x7D else { return nil }
            rest.append(contentsOf: members)
        case 0x7D where after.count == 1:  // "}": data was the only member
            rest.append(0x7D)
        default:
            return nil
        }
        return OutputLineFastPath(base64: start..<close, rest: rest)
    }

    /// The bytes the JSON parser reads to route `line` (its envelope): the members other than `data` for an output
    /// line, else the whole line.
    static func envelopeText(_ line: Data) -> Data {
        split(line)?.rest ?? line
    }

    /// The terminal bytes of `line`'s `data`, base64-decoded as JSONDecoder decodes a `Data` field; nil when the
    /// text is not valid base64.
    func data(in line: Data) -> Data? {
        Data(base64Encoded: line.dropFirst(base64.lowerBound).prefix(base64.count))
    }
}
