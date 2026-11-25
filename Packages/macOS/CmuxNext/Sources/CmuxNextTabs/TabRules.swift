import CCmuxLayoutReducerFFI
import Foundation

/// The tab strip's rules in Rust (cmux-window-rules `tabs::selection` and `tabs::strip`), asked over the app FFI's
/// JSON channel (`cmux_layout_reducer_json`, ops `tab_selection*` and `tab_strip_*`).
nonisolated enum TabRules {
    /// One call; nil when the channel refuses (a request the rule cannot read), which a debug build stops on.
    static func call<Reply: Decodable>(_ operation: String, _ request: some Encodable) -> Reply? {
        guard let data = try? JSONEncoder().encode(request) else { return nil }
        var capacity = 1024
        for _ in 0..<2 {
            var output = [UInt8](repeating: 0, count: capacity)
            var outputLength = 0
            let code: Int32 = data.withUnsafeBytes { requestBytes in
                output.withUnsafeMutableBytes { outputBytes in
                    cmux_layout_reducer_json(requestBytes.bindMemory(to: UInt8.self).baseAddress, data.count, operation,
                                             outputBytes.bindMemory(to: UInt8.self).baseAddress, outputBytes.count, &outputLength)
                }
            }
            if code == CMUX_LAYOUT_REDUCER_ERR_BUFFER, outputLength > capacity {
                capacity = outputLength
                continue
            }
            guard code == CMUX_LAYOUT_REDUCER_OK, outputLength <= capacity else { break }
            return try? JSONDecoder().decode(Reply.self, from: Data(output.prefix(outputLength)))
        }
        assertionFailure("\(operation) refused")
        return nil
    }
}
