import CCmuxLayoutReducerFFI
import Foundation

/// What the Rust drop rules read and answer for a file drop (`drop_transfer_mode`): device ids
/// (none: unknown) and the modifiers; the reply is `copy` or `move`. No rule lives here.
enum DropTransferWire {
    struct Request: Encodable { var sources: [Int?], destination: Int?, option: Bool, command: Bool }
    struct Reply: Decodable { var mode: String }

    /// One JSON call of the app FFI (`cmux_layout_reducer_json`); nil when it does not answer.
    static func ask(_ request: Request) -> Reply? {
        guard let data = try? JSONEncoder().encode(request) else { return nil }
        var output = [UInt8](repeating: 0, count: 256)
        var length = 0
        let code: Int32 = data.withUnsafeBytes { bytes in
            "drop_transfer_mode".withCString { op in
                output.withUnsafeMutableBytes { out in
                    cmux_layout_reducer_json(bytes.bindMemory(to: UInt8.self).baseAddress, data.count, op,
                                             out.bindMemory(to: UInt8.self).baseAddress, out.count, &length)
                }
            }
        }
        guard code == CMUX_LAYOUT_REDUCER_OK, length <= output.count else { return nil }
        return try? JSONDecoder().decode(Reply.self, from: Data(output.prefix(length)))
    }
}
