import Foundation

/// One batch of a chat's changes on its way to the page (the design doc's host contract): the
/// core's change bytes, each passed as it is. The host reads a change's `kind` and nothing else,
/// and builds the page's one call's argument, `{batch, changes}` for `window.cmuxChatRows.receive`, in one pass
/// off the main actor. Nothing here parses a row or encodes a change again.
nonisolated struct AcpmuxChatRowsBatch: Sendable {
    /// The script's head and tail around the change strings.
    static let receiver = "window.cmuxChatRows.receive"

    /// The changes of a batch the byte driver framed (``AcpmuxClientByteConnection`` with
    /// `framesChanges`): each change is a 4-byte big-endian length, then its bytes. A blob change
    /// holds a newline, so the batch cannot be split on one. Nil for bytes that are not frames.
    static func changes(inFramed batch: Data) -> [Data]? {
        var changes: [Data] = []
        var index = batch.startIndex
        while index < batch.endIndex {
            guard batch.endIndex - index >= 4 else { return nil }
            var length = 0
            for offset in 0..<4 { length = length << 8 | Int(batch[index + offset]) }
            let start = index + 4
            guard batch.endIndex - start >= length else { return nil }
            changes.append(batch[start..<start + length])
            index = start + length
        }
        return changes
    }

    /// A change's `kind`: the first `"kind":"` key in its bytes. The core writes `kind` before any
    /// row (`{"kind":"chatWindow",...`), and its `fallback` change holds only numbers before it
    /// (`{"bytes":[...],"kind":"fallback"}`), so a row's own `kind` is never the first.
    static func kind(of change: Data) -> String? {
        let key = Data("\"kind\":\"".utf8)
        guard let found = change.range(of: key) else { return nil }
        let start = found.upperBound
        guard let end = change[start...].firstIndex(of: UInt8(ascii: "\"")) else { return nil }
        return String(decoding: change[start..<end], as: UTF8.self)
    }

    /// The page's call for batch `number` as one script text: ``receiver`` around ``argument(batch:changes:)``.
    /// Benches and tests read it; the host pushes ``receiveBody`` with the argument instead.
    static func script(batch number: Int, changes: [Data]) -> String {
        "\(receiver)(\(argument(batch: number, changes: changes)))"
    }

    /// The fixed body the page runs for every batch, the batch's JSON text as its `batch` argument
    /// (`callAsyncJavaScript`). A new script text per batch made WebKit's web process keep each one:
    /// +8.45 MB/min at 20 pushes a second, -0.48 MB/min with the same data as an argument (RFD 0062,
    /// renderer idle growth; webviews/bench/webkit-push-growth.bench.ts).
    static let receiveBody = "\(receiver)(JSON.parse(batch));"

    /// Batch `number` as JSON text, `{"batch":N,"changes":[...]}`: each change as one JSON string of
    /// its exact bytes.
    static func argument(batch number: Int, changes: [Data]) -> String {
        var out: [UInt8] = []
        out.reserveCapacity(changes.reduce(48) { $0 + $1.count + $1.count / 8 + 3 })
        out.append(contentsOf: Array("{\"batch\":\(number),\"changes\":[".utf8))
        for (index, change) in changes.enumerated() {
            if index > 0 { out.append(UInt8(ascii: ",")) }
            appendString(change, to: &out)
        }
        out.append(contentsOf: Array("]}".utf8))
        return String(decoding: out, as: UTF8.self)
    }

    /// Appends `bytes` as a JSON string literal: quotes, backslashes and control characters
    /// escaped, U+2028 and U+2029 too (a line break in a script), every other byte as it is.
    private static func appendString(_ bytes: Data, to out: inout [UInt8]) {
        let hex = Array("0123456789abcdef".utf8)
        out.append(UInt8(ascii: "\""))
        var index = bytes.startIndex
        while index < bytes.endIndex {
            let byte = bytes[index]
            switch byte {
            case UInt8(ascii: "\""): out.append(contentsOf: [0x5C, 0x22])
            case UInt8(ascii: "\\"): out.append(contentsOf: [0x5C, 0x5C])
            case 0x0A: out.append(contentsOf: [0x5C, UInt8(ascii: "n")])
            case 0x0D: out.append(contentsOf: [0x5C, UInt8(ascii: "r")])
            case 0x09: out.append(contentsOf: [0x5C, UInt8(ascii: "t")])
            case 0x00..<0x20:
                out.append(contentsOf: Array("\\u00".utf8))
                out.append(hex[Int(byte >> 4)])
                out.append(hex[Int(byte & 0x0F)])
            case 0xE2 where bytes.endIndex - index >= 3 && bytes[index + 1] == 0x80
                && (bytes[index + 2] == 0xA8 || bytes[index + 2] == 0xA9):
                out.append(contentsOf: Array((bytes[index + 2] == 0xA8 ? "\\u2028" : "\\u2029").utf8))
                index += 2
            default: out.append(byte)
            }
            index += 1
        }
        out.append(UInt8(ascii: "\""))
    }

    /// Whether `name` may name a sid or a blob id (decision 228): `<prefix>.<n>`, at most 64
    /// bytes of `A-Za-z0-9._-`, the prefix not empty and `n` digits.
    static func isName(_ name: String) -> Bool {
        let bytes = Array(name.utf8)
        guard !bytes.isEmpty, bytes.count <= 64,
              bytes.allSatisfy({ isNameByte($0) }),
              let dot = bytes.lastIndex(of: UInt8(ascii: ".")), dot > 0, dot < bytes.count - 1
        else { return false }
        return bytes[(dot + 1)...].allSatisfy { (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) }
    }

    private static func isNameByte(_ byte: UInt8) -> Bool {
        switch byte {
        case UInt8(ascii: "A")...UInt8(ascii: "Z"), UInt8(ascii: "a")...UInt8(ascii: "z"),
             UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "."), UInt8(ascii: "_"), UInt8(ascii: "-"):
            true
        default: false
        }
    }
}
