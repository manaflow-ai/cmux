import CCmuxLayoutReducerFFI
public import Foundation
import os

/// The drop-target rules, asked of Rust (cmux-tui/crates/cmux-layout-reducer `drop_rules`, with their
/// table tests) over the app FFI's JSON channel (`cmux_layout_reducer_json`, ops `drop_*`): where a
/// dragged tab or group lands, how a workspace drag ends, what a link drop does. The app keeps the drag
/// session, the pasteboard and the hit test, sends the facts and applies the answer. Lives beside
/// ``TabDropKind`` so the tab strip and the app ask through one channel.
public nonisolated enum DropRules {
    /// One JSON call; nil when Rust does not answer (a pinned FFI without the op, a non-finite number).
    public static func call<Request: Encodable, Reply: Decodable>(_ operation: String, _ request: Request, as: Reply.Type) -> Reply? {
        guard let data = try? JSONEncoder().encode(request), let reply = callData(operation, data),
              let decoded = try? JSONDecoder().decode(Reply.self, from: reply) else {
            log.fault("drop rule \(operation, privacy: .public) did not answer")
            return nil
        }
        return decoded
    }

    private static func callData(_ operation: String, _ data: Data) -> Data? {
        var capacity = 1024
        for _ in 0..<2 {
            var output = [UInt8](repeating: 0, count: capacity)
            var length = 0
            let code: Int32 = data.withUnsafeBytes { bytes in
                operation.withCString { op in
                    output.withUnsafeMutableBytes { out in
                        cmux_layout_reducer_json(bytes.bindMemory(to: UInt8.self).baseAddress, data.count, op,
                                                 out.bindMemory(to: UInt8.self).baseAddress, out.count, &length)
                    }
                }
            }
            if code == CMUX_LAYOUT_REDUCER_ERR_BUFFER, length > capacity { capacity = length; continue }
            guard code == CMUX_LAYOUT_REDUCER_OK, length <= capacity else { return nil }
            return Data(output.prefix(length))
        }
        return nil
    }

    private static let log = Logger(subsystem: "com.cmuxterm.app.next", category: "drop-rules")
}
