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
