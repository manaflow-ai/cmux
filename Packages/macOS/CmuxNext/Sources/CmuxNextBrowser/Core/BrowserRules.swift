import CCmuxLayoutReducerFFI
import Foundation
import os

/// The browser pane's rules, asked of Rust (cmux-tui/crates/cmux-browser-rules, with their tests)
/// over the app FFI's JSON channel (`cmux_layout_reducer_json`, ops `browser_rules_*`). The engines
/// read the facts (a click's modifiers, Chromium's request), ask here and apply the answer; the
/// rules live in Rust only (cmuxterm-hq docs/rfd/drafts/why-swift.md, "Browser pane hosting").
/// Rust reads and writes the shape Swift's synthesized `Codable` gives these types, so a type
/// on the wire only declares `Codable`.
nonisolated enum BrowserRules {
    /// One JSON call of the app FFI; nil when it does not answer (a pinned FFI without the op).
    static func call<Request: Encodable, Reply: Decodable>(_ operation: String, _ request: Request,
                                                          as: Reply.Type) -> Reply? {
        guard let data = try? JSONEncoder().encode(request), let reply = callData(operation, data),
              let decoded = try? JSONDecoder().decode(Reply.self, from: reply) else {
            log.fault("browser rule \(operation, privacy: .public) did not answer")
            return nil
        }
        return decoded
    }

    private static func callData(_ operation: String, _ data: Data) -> Data? {
        var capacity = 1024
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

    private static let log = Logger(subsystem: "com.cmuxterm.app.next", category: "browser-rules")
}
