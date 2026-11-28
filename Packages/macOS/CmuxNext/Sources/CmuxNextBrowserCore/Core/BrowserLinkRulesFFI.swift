import CCmuxLayoutReducerFFI
package import Foundation

/// The link routing rules answered by the app's Rust library (cmux-tui/crates/cmux-browser-rules,
/// `link_routes.rs`, with their tests) over the app FFI's JSON channel (`cmux_layout_reducer_json`,
/// ops `browser_rules_link_*`). Swift reads the facts (a URL's scheme and host) and acts on the answer.
package nonisolated enum BrowserLinkRulesFFI {
    /// Calls op `browser_rules_link_<name>` with a JSON request; nil when the library does not answer.
    package static func call(_ name: String, _ request: [String: Any]) -> Any? {
        guard let data = try? JSONSerialization.data(withJSONObject: request),
              let reply = callData("browser_rules_link_" + name, data) else { return nil }
        return try? JSONSerialization.jsonObject(with: reply, options: [.fragmentsAllowed])
    }

    /// One `cmux_layout_reducer_json` call, retried once at the size it asks for.
    private static func callData(_ operation: String, _ data: Data) -> Data? {
        var capacity = 512
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

    /// `url`'s scheme and host as the ops take an address; null for no URL.
    package static func address(_ url: URL?) -> Any {
        guard let url else { return NSNull() }
        return ["scheme": url.scheme ?? NSNull(), "host": url.host ?? NSNull()] as [String: Any]
    }
}
