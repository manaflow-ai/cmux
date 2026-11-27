import CCmuxLayoutReducerFFI
import CmuxScreenKit
import Foundation

/// The screen stream host's rules (CmuxVNCWebRTC's ``ScreenRules``: viewer demand, the viewer's
/// caps, the cursor shape, follow mode's focus producer) answered by the app's Rust library
/// (cmux-rd-screen through cmux-layout-reducer-ffi's `screen_*` ops), handed to every host and
/// capture this app starts (``MacScreenStreamChild``, ``MacScreenRdHost``, ``MacDisplayCapture``).
nonisolated enum MacScreenRules {
    static var rules: ScreenRules {
        ScreenRules { operation, data in call(operation, data) }
    }

    /// One `cmux_layout_reducer_json` call, retried once at the size it asks for.
    private static func call(_ operation: String, _ data: Data) -> Data? {
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

nonisolated extension MacScreenRules {
    /// One `rd_devices_*` call (cmux-rd-core's rd_devices rules), decoded; nil when Rust does not answer.
    static func rdDevices<T: Decodable>(_ operation: String, _ request: Any, as _: T.Type) -> T? {
        guard let data = try? JSONSerialization.data(withJSONObject: request, options: .fragmentsAllowed),
              let answer = call(operation, data) else { return nil }
        return try? JSONDecoder().decode(T.self, from: answer)
    }
}

/// cmux-rd-core's `Words`: a localized format (`key`, its English `text`, `table`) with each `%@`
/// filled from `args` the same way, or words not localized (`key` nil).
nonisolated struct RdWords: Decodable, Sendable {
    var key: String?
    var text: String
    var table: String?
    var args: [RdWords]?

    var string: String {
        let format = key.map { Bundle.localizedModule.localizedString(forKey: $0, value: text, table: table) } ?? text
        guard let args, !args.isEmpty else { return format }
        return String(format: format, arguments: args.map { $0.string as any CVarArg })
    }
}
