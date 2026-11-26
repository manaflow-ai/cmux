import CCmuxLayoutReducerFFI
public import Foundation
import os

/// Settings › Import's rules, asked of Rust (cmux-tui/crates/cmux-import-suggest, with their tests)
/// over the app FFI's JSON channel (`cmux_layout_reducer_json`, ops `import_suggest_*`). The cards,
/// dismissals, requests, job transitions, scan decisions, iTerm2's colors and the classic prompt's
/// plan are decided there; Swift reads the files, keeps the saved state and puts words on the keys
/// (Leo, 2026-11-25: "Figure out how you can fan the fuck out and parallelize each piece and get
/// stuff landed asap"). Requests and replies use `JSONEncoder.importJobs`, so dates are the
/// milliseconds since 1970 the Rust side reads.
nonisolated enum ImportSuggestRules {
    /// One JSON call (`import_suggest_<operation>`); nil when it does not answer (a pinned FFI without the op).
    static func call<Reply: Decodable>(_ operation: String, _ fields: [String: any Encodable], as: Reply.Type = Reply.self) -> Reply? {
        let name = "import_suggest_" + operation
        guard let data = try? JSONEncoder.importJobs.encode(Fields(values: fields)), let reply = callData(name, data),
              let decoded = try? JSONDecoder.importJobs.decode(Reply.self, from: reply) else {
            log.fault("import rule \(name, privacy: .public) did not answer")
            return nil
        }
        return decoded
    }

    private static func callData(_ operation: String, _ data: Data) -> Data? {
        var capacity = 4096
        for _ in 0..<2 {
            var output = [UInt8](repeating: 0, count: capacity); var outputLength = 0
            let code: Int32 = data.withUnsafeBytes { requestBytes in operation.withCString { operationCString in output.withUnsafeMutableBytes { outputBytes in cmux_layout_reducer_json(requestBytes.bindMemory(to: UInt8.self).baseAddress, data.count, operationCString, outputBytes.bindMemory(to: UInt8.self).baseAddress, outputBytes.count, &outputLength) } } }
            if code == CMUX_LAYOUT_REDUCER_ERR_BUFFER, outputLength > capacity {
                capacity = outputLength
                continue
            }
            guard code == CMUX_LAYOUT_REDUCER_OK, outputLength <= capacity else { return nil }
            return Data(output.prefix(outputLength))
        }
        return nil
    }

    /// A request's fields, each coded as itself.
    private struct Fields: Encodable {
        var values: [String: any Encodable]

        struct Key: CodingKey {
            var stringValue: String
            var intValue: Int? { nil }
            init(stringValue: String) { self.stringValue = stringValue }
            init?(intValue: Int) { nil }
        }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: Key.self)
            for (key, value) in values { try container.encode(value, forKey: Key(stringValue: key)) }
        }
    }

    /// A date that came back from Rust: the one sent when it is that one to within the millisecond
    /// coding (Rust passes it through or sets it to `now`), so equality survives the round trip.
    static func pinned(_ date: Date, to candidates: Date...) -> Date {
        candidates.first { abs($0.timeIntervalSince(date)) < 0.002 } ?? date
    }

    private static let log = Logger(subsystem: "com.cmuxterm.app.next", category: "import-suggestions")
}
