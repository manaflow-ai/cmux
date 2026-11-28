import CCmuxLayoutReducerFFI
import Foundation

/// The browser automation's rules answered by the app's Rust library (cmux-tui/crates/cmux-browser-rules,
/// with their tests) over the app FFI's JSON channel (`cmux_layout_reducer_json`, ops
/// `browser_rules_automation_*`). Swift reads the facts (a call's params, WebKit's frame tree) and acts
/// on the answer; the rules stay in Rust.
nonisolated enum BrowserRulesFFI {
    /// Calls automation op `name` with a JSON request; nil when the library does not answer.
    static func call(_ name: String, _ request: [String: Any]) -> DriverJSON? {
        guard let data = try? JSONSerialization.data(withJSONObject: request) else { return nil }
        return call(name, data: data)
    }

    /// Calls automation op `name` with encoded JSON; nil when the library does not answer.
    static func call(_ name: String, data: Data) -> DriverJSON? {
        guard let reply = callData("browser_rules_automation_" + name, data),
              let object = try? JSONSerialization.jsonObject(with: reply, options: [.fragmentsAllowed]) else { return nil }
        return DriverJSON(foundation: object)
    }

    /// `value` as JSON Foundation can write. JSON has no NaN or infinity: such a number crosses as 0,
    /// still a number, so a caller that needs a finite number checks it before asking.
    static func foundation(_ value: DriverJSON) -> Any {
        switch value {
        case .null: NSNull()
        case .bool(let flag): flag
        case .number(let number): number.isFinite ? number : 0
        case .string(let string): string
        case .array(let items): items.map(foundation)
        case .object(let fields): fields.mapValues(foundation)
        }
    }

    /// One `cmux_layout_reducer_json` call, retried once at the size it asks for.
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
}
