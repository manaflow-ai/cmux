internal import CCmuxLayoutReducerFFI
import CmuxVNC
import Foundation

#if DEBUG
/// The RFB client's rules (CmuxVNC's ``VNCRules``: the version banner, the security choice, the
/// VNC password and Apple DH responses) answered by the app's Rust library (cmux-vnc through
/// cmux-layout-reducer-ffi's `vnc_*` ops), handed to every ``RemoteVNCSource`` client.
nonisolated enum RemoteVNCRules {
    static let rules = VNCRules { operation, data in call(operation, data) }

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
#endif
