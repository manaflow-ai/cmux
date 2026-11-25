import CCmuxLayoutReducerFFI
public import Foundation
import os

/// The window handlers' rules, asked of Rust (cmux-tui/crates/cmux-window-rules, with their tests)
/// over the app FFI's JSON channel (`cmux_layout_reducer_json`, ops `window_*`). A handler reads the
/// facts (its models, the settings, the daemon's answers), asks here, and applies the answer: the
/// dialog, the toast, the daemon command, the localized text. The rules stay in Rust (Leo,
/// 2026-11-06: "ok we need to go all hands on deck here. don't just do baby steps. we can just... do it").
public nonisolated struct WindowRules: Sendable {
    public init() {}

    /// One JSON call of the app FFI; nil when it does not answer (a pinned FFI without the op).
    public func call<Request: Encodable, Reply: Decodable>(_ operation: String, _ request: Request, as: Reply.Type) -> Reply? {
        guard let data = try? JSONEncoder().encode(request), let reply = callData(operation, data),
              let decoded = try? JSONDecoder().decode(Reply.self, from: reply) else {
            Self.log.fault("window rule \(operation, privacy: .public) did not answer")
            return nil
        }
        return decoded
    }

    private func callData(_ operation: String, _ data: Data) -> Data? {
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

    private static let log = Logger(subsystem: "com.cmuxterm.app.next", category: "window-rules")
}
