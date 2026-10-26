import CmuxFuzzSupport
import Foundation
@testable import CmuxNextDaemon

/// ``LineSplitter`` against a byte-by-byte model: the same lines (empty ones skipped) and the same unfinished
/// rest for one read, random chunks and one to three bytes a read, and every byte searched once.
enum WireFuzzSplitterCase {
    /// Bytes with newlines often enough to cut many lines, empty ones included; now and then a long stream.
    static func stream(_ rng: inout FuzzRNG) -> [UInt8] {
        let count = rng.oneIn(16) ? 1 + rng.below(70_000) : rng.below(600)
        let newlineOdds = 1 + rng.below(40)
        return (0..<count).map { _ in rng.oneIn(newlineOdds) ? 0x0A : rng.byte() }
    }

    static func check(_ stream: [UInt8], _ rng: inout FuzzRNG) throws {
        var expected: [[UInt8]] = []
        var rest: [UInt8] = []
        for byte in stream {
            if byte == 0x0A {
                if !rest.isEmpty { expected.append(rest) }
                rest = []
            } else {
                rest.append(byte)
            }
        }
        var splitter = LineSplitter()
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
            splitter.append(stream[at..<(at + count)]) { lines.append([UInt8]($0)) }
            at += count
        }
        try FuzzRun.check(lines == expected, "mode \(mode): \(lines.count) lines, the model cut \(expected.count) from \(stream.count) bytes")
        try FuzzRun.check([UInt8](splitter.pending) == rest,
                          "mode \(mode): the unfinished rest is \(splitter.pending.count) bytes, not \(rest.count)")
        try FuzzRun.check(splitter.scannedBytes == stream.count, "searched \(splitter.scannedBytes) bytes of \(stream.count): not once each")
        try checkNewlineOffsets(stream, &rng)
    }

    /// The offsets count from the data's first byte, also for a slice whose start index is not 0.
    private static func checkNewlineOffsets(_ stream: [UInt8], _ rng: inout FuzzRNG) throws {
        let data = Data(stream)
        let drop = rng.below(min(data.count, 8) + 1)
        let slice = data[(data.startIndex + drop)...]
        let offset = rng.below(slice.count + 2)
        let expected = offset < slice.count ? (offset..<slice.count).filter { slice[slice.startIndex + $0] == 0x0A } : []
        let (offsets, searched) = LineSplitter.newlineOffsets(in: slice, from: offset)
        try FuzzRun.check(offsets == expected, "newline offsets from \(offset) of a \(slice.count) byte slice differ")
        try FuzzRun.check(searched == max(slice.count - offset, 0), "searched \(searched) bytes from \(offset) of \(slice.count)")
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

    /// Bytes that are never JSON: a `#` first, and no newline.
    static func garbage(_ rng: inout FuzzRNG) -> WireFuzzLine {
        let tail = rng.bytes(count: rng.below(48)).map { $0 == 0x0A ? 0x20 : $0 }
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
/// throws.
enum WireFuzzEnvelopeCase {
    static func isStream(_ type: String?) -> Bool { type == "stream_item" || type == "stream_end" }

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
        let mutated = FuzzMutator(dictionary: WireFuzzJSON.tokens).mutate(Data(line.bytes), using: &rng)
        _ = try? decoder.decode(LineTransport.Envelope.self, from: mutated)
    }
}
