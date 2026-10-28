import CmuxFuzzSupport
import CmuxNextIPC
import Foundation
@testable import CmuxNextDaemon

/// The transport's ``FrameReader`` against a byte-by-byte model on JSON-line traffic (valid UTF-8, no frames):
/// the same lines, empty ones included, and the same unfinished rest at the end, for one read, random chunks
/// and one to three bytes a read, with a multi-byte character cut anywhere.
enum WireFuzzLineCutCase {
    /// UTF-8 pieces with newlines often enough to cut many lines, empty ones included; now and then a long stream.
    static func stream(_ rng: inout FuzzRNG) -> [UInt8] {
        let pieces: [[UInt8]] = [Array("é".utf8), Array("✓".utf8), Array("\u{1F600}".utf8), [0x7B], [0x22], [0x09]]
        let count = rng.oneIn(16) ? 1 + rng.below(70_000) : rng.below(600)
        let newlineOdds = 1 + rng.below(40)
        var stream: [UInt8] = []
        while stream.count < count {
            if rng.oneIn(newlineOdds) {
                stream.append(0x0A)
            } else if rng.oneIn(8) {
                stream += pieces[rng.below(pieces.count)]
            } else {
                stream.append(0x20 + UInt8(rng.below(0x5F)))
            }
        }
        return stream
    }

    static func check(_ stream: [UInt8], _ rng: inout FuzzRNG) throws {
        var expected: [[UInt8]] = []
        var rest: [UInt8] = []
        for byte in stream {
            if byte == 0x0A {
                expected.append(rest)
                rest = []
            } else {
                rest.append(byte)
            }
        }
        if !rest.isEmpty { expected.append(rest) }
        var reader = FrameReader(limits: FrameReader.Limits(maxLine: LineTransport.maxLineBytes))
        var lines: [[UInt8]] = []
        let mode = rng.below(3)
        var at = 0
        while at < stream.count {
            let left = stream.count - at
            let count: Int
            switch mode {
            case 0: count = left
            case 1: count = 1 + rng.below(left)
            default: count = min(left, 1 + rng.below(3))
            }
            // SAFETY: push copies the slice's bytes out of the storage the closure lends for the call.
            unsafe stream[at..<(at + count)].withUnsafeBytes { unsafe reader.push($0) }
            try drain(&reader, into: &lines)
            at += count
        }
        reader.markEndOfStream()
        try drain(&reader, into: &lines)
        try FuzzRun.check(lines == expected, "mode \(mode): \(lines.count) lines, the model cut \(expected.count) from \(stream.count) bytes")
    }

    private static func drain(_ reader: inout FrameReader, into lines: inout [[UInt8]]) throws {
        while true {
            let message: FrameReader.Message?
            do throws(BadMessage) {
                message = try reader.next()
            } catch {
                return try FuzzRun.check(false, "the reader refused UTF-8 JSON-line traffic: \(error.reason)")
            }
            guard let message else { return }
            guard case .json(let line) = message else { return try FuzzRun.check(false, "a frame out of JSON-line traffic") }
            lines.append([UInt8](line))
        }
    }
}

/// One wire line and how the routing contract of ``LineTransport`` (its type comment and `Envelope`'s)
/// treats it.
struct WireFuzzLine {
    enum Route: Equatable {
        /// Not JSON, or JSON with no `event`, stream `type`, `ok` or `id`.
        case ignored
        case event(name: String)
        /// A `cmux.protocol/2` stream line. With no `stream_id` it travels as an event; with one it is an
        /// event while that id is a control stream (until its `stream_end`), else it goes to the stream
        /// handler, or is dropped when there is none.
        case stream(type: String, streamID: String?)
        /// A reply: its usable id (nil: the oldest pending request), its `ok`, and its error text.
        case reply(id: UInt64?, ok: Bool?, message: String?)
    }

    var bytes: [UInt8]
    var route: Route

    /// A line of any kind; replies name ids `1...requests` (pending) or the two above them (not pending).
    static func random(_ rng: inout FuzzRNG, requests: Int) throws -> WireFuzzLine {
        switch rng.below(12) {
        case 0...3: return try reply(&rng, requests: requests)
        case 4...6: return try event(&rng)
        case 7: return try stream(&rng)
        case 8: return garbage(&rng)
        case 9: return try ignoredJSON(&rng)
        default: return WireFuzzLine(bytes: [], route: .ignored)
        }
    }

    static func reply(_ rng: inout FuzzRNG, requests: Int) throws -> WireFuzzLine {
        var object: [String: Any] = [:]
        let wanted = UInt64(1 + rng.below(requests + 2))
        var id: UInt64?
        switch rng.below(7) {
        case 0, 1:
            object["id"] = Int(wanted)
            id = wanted
        case 2:
            object["id"] = String(wanted)
            id = wanted
        case 3: object["id"] = "\(wanted)x"
        case 4: object["id"] = -1
        default: break
        }
        var ok: Bool?
        switch rng.below(5) {
        case 0, 1:
            object["ok"] = true
            ok = true
        case 2:
            object["ok"] = false
            ok = false
        case 3: object["ok"] = "yes"
        default: break
        }
        var message: String?
        let text = rng.text(WireFuzzJSON.text, 16)
        let code = "E_" + rng.text(WireFuzzJSON.keys, 5)
        switch rng.below(6) {
        case 0, 1:
            object["error"] = text
            message = text
        case 2:
            object["error"] = ["message": text, "code": code] as [String: Any]
            message = text
        case 3:
            object["error"] = ["code": code, "retryable": rng.bool()] as [String: Any]
            message = code
        case 4: object["error"] = 7
        default: break
        }
        if rng.oneIn(2) { object["data"] = WireFuzzJSON.value(&rng) }
        if rng.oneIn(4) { object["error_code"] = code }
        if rng.oneIn(6) { object["reason"] = "r" }
        let route: Route = ok == nil && id == nil ? .ignored : .reply(id: id, ok: ok, message: message)
        return WireFuzzLine(bytes: try WireFuzzJSON.bytes(object), route: route)
    }

    static func event(_ rng: inout FuzzRNG) throws -> WireFuzzLine {
        let names = ["title-changed", "bell", "tab-added", "notification", "x", "é✓"]
        let name: String
        if rng.oneIn(30) {
            name = "daemon-shutdown"
        } else if rng.oneIn(4) {
            name = rng.text(WireFuzzJSON.text, 10)
        } else {
            name = names[rng.below(names.count)]
        }
        var object = WireFuzzJSON.object(&rng)
        object["event"] = name
        // The event field wins over reply fields.
        if rng.oneIn(5) { object["id"] = 1 + rng.below(4) }
        if rng.oneIn(5) { object["ok"] = rng.bool() }
        return WireFuzzLine(bytes: try WireFuzzJSON.bytes(object), route: .event(name: name))
    }

    /// The ids a stream line names; a transport case opens some of them as control streams.
    static let streamIDs = ["s0", "s1", "s2"]

    static func stream(_ rng: inout FuzzRNG) throws -> WireFuzzLine {
        let type = rng.bool() ? "stream_item" : "stream_end"
        var object: [String: Any] = ["type": type, "item": WireFuzzJSON.value(&rng)]
        let streamID: String? = rng.oneIn(4) ? nil : streamIDs[rng.below(streamIDs.count)]
        if let streamID { object["stream_id"] = streamID }
        return WireFuzzLine(bytes: try WireFuzzJSON.bytes(object), route: .stream(type: type, streamID: streamID))
    }

    /// Text that is never JSON: a `#` first, printable ASCII, and no newline. The daemon writes UTF-8 only;
    /// a line that is not UTF-8 is a bad message that ends the connection (the reader's own rule).
    static func garbage(_ rng: inout FuzzRNG) -> WireFuzzLine {
        let tail = rng.bytes(count: rng.below(48)).map { 0x20 + $0 % 0x5F }
        return WireFuzzLine(bytes: [UInt8(ascii: "#")] + tail, route: .ignored)
    }

    /// JSON that names no route: no `ok` or `id`, no string `event`, no stream `type`.
    static func ignoredJSON(_ rng: inout FuzzRNG) throws -> WireFuzzLine {
        let object: Any
        switch rng.below(5) {
        case 0: object = ["error": "e", "x": 1] as [String: Any]
        case 1: object = ["event": 5]
        case 2: object = ["type": "stream_other", "ok": "no"]
        case 3: object = [1, 2, ["ok": true]] as [Any]
        default: object = rng.text(WireFuzzJSON.text, 8)
        }
        return WireFuzzLine(bytes: try WireFuzzJSON.bytes(object), route: .ignored)
    }
}

/// ``LineTransport/Envelope`` reads the routing fields of every generated line; a mutated line decodes or
/// throws. ``LineRouteScan``, which routes in its place, reads the same fields or gives the line up.
enum WireFuzzEnvelopeCase {
    static func isStream(_ type: String?) -> Bool { type == "stream_item" || type == "stream_end" }

    /// When the scan reads a UTF-8 line (the reader's guarantee), the decoder reads it too, to the same routing
    /// fields; any bytes at all never trap the scan.
    static func checkScanAgrees(_ line: Data) throws {
        guard let scan = LineRouteScan(line), isUTF8(line) else { return }
        let shown = String(decoding: line.prefix(200), as: UTF8.self)
        let decoded = try? WireCoding.decoder().decode(LineTransport.Envelope.self, from: line)
        let read = try WireFuzzJSON.required(decoded, "the scan routes a line the decoder refuses: \(shown)")
        try FuzzRun.check(scan.id == read.id && scan.ok == read.ok && scan.event == read.event && scan.type == read.type
                              && scan.streamID == read.streamID && scan.cause == read.cause && scan.stream == read.stream,
                          "the scan read \(scan), the decoder \(read): \(shown)")
    }

    /// One line of strict UTF-8, as the transport's reader hands it on (no newline inside).
    static func isUTF8(_ line: Data) -> Bool {
        guard !line.contains(0x0A) else { return false }
        var reader = FrameReader(limits: FrameReader.Limits(maxLine: line.count))
        // SAFETY: push copies the bytes out of the storage the closure lends for the call.
        unsafe (line + [UInt8(0x0A)]).withUnsafeBytes { unsafe reader.push($0) }
        guard case .json? = try? reader.next() else { return false }
        return true
    }

    static func check(_ line: WireFuzzLine, _ rng: inout FuzzRNG) throws {
        let decoder = WireCoding.decoder()
        let envelope = try? decoder.decode(LineTransport.Envelope.self, from: Data(line.bytes))
        let shown = String(decoding: line.bytes.prefix(200), as: UTF8.self)
        switch line.route {
        case .ignored:
            if let envelope {
                try FuzzRun.check(envelope.event == nil && envelope.ok == nil && envelope.id == nil && !isStream(envelope.type),
                                  "an ignored line routes: \(shown)")
            }
        case .event(let name):
            try FuzzRun.check(envelope?.event == name, "event \(name) decoded as \(String(describing: envelope?.event)): \(shown)")
        case .stream(let type, let streamID):
            let read = try WireFuzzJSON.required(envelope, "a stream line does not decode: \(shown)")
            try FuzzRun.check(read.event == nil && read.type == type && read.streamID == streamID, "stream line misread: \(shown)")
        case .reply(let id, let ok, let message):
            let read = try WireFuzzJSON.required(envelope, "a reply line does not decode: \(shown)")
            try FuzzRun.check(read.event == nil, "a reply has an event: \(shown)")
            try FuzzRun.check(read.id == id, "reply id \(String(describing: read.id)), want \(String(describing: id)): \(shown)")
            try FuzzRun.check(read.ok == ok, "reply ok \(String(describing: read.ok)), want \(String(describing: ok)): \(shown)")
            try FuzzRun.check(read.error == message,
                              "reply error \(String(describing: read.error)), want \(String(describing: message)): \(shown)")
        }
        try checkScanAgrees(Data(line.bytes))
        let mutated = FuzzMutator(dictionary: WireFuzzJSON.tokens).mutate(Data(line.bytes), using: &rng)
        _ = try? decoder.decode(LineTransport.Envelope.self, from: mutated)
        try checkScanAgrees(mutated)
    }
}
