import CCmuxLayoutReducerFFI
import CmuxNextCompat
import Foundation

/// The pane's optimistic rows, computed by the Tasks owner's own reducer
/// (cmux-tasks-core `tasks_preview` over the app FFI): pending intents are
/// replayed on the confirmed mirror, so the pane never re-derives owner
/// rules (task keys, default status, sort keys, delegate principals).
nonisolated enum TasksPreview {
    struct Mirror: Encodable {
        var seq: UInt64
        var me: TaskPrincipal
        var settings: TasksSettings
        var statuses: [TaskStatusItem]
        var labels: [TaskLabelItem]
        var projects: [TaskProjectItem]
        var tasks: [TaskItem]
        var sessions: [TaskSessionItem]
    }

    struct Intent: Encodable {
        var key: String
        var op: String
        var params: [String: TasksJSON]
    }

    struct Request: Encodable {
        var mirror: Mirror
        var intents: [Intent]
        var now: Int64
    }

    struct Response: Decodable {
        var tasks: [TaskItem]
        var rejected: [String]
    }

    /// The first output buffer; a larger reply returns ERR_BUFFER with the
    /// needed length, and the call runs once more with that size.
    static let initialCapacity = 64 * 1024

    static func run(_ request: Request) -> Response? {
        guard let data = try? JSONEncoder().encode(request) else { return nil }
        var capacity = initialCapacity
        for _ in 0..<2 {
            var output = [UInt8](repeating: 0, count: capacity); var outputLength = 0
            let code: Int32 = data.withUnsafeBytes { requestBytes in "tasks_preview".withCString { operation in output.withUnsafeMutableBytes { outputBytes in cmux_layout_reducer_json(requestBytes.bindMemory(to: UInt8.self).baseAddress, data.count, operation, outputBytes.bindMemory(to: UInt8.self).baseAddress, outputBytes.count, &outputLength) } } }
            if code == CMUX_LAYOUT_REDUCER_ERR_BUFFER, outputLength > capacity {
                capacity = outputLength
                continue
            }
            guard code == CMUX_LAYOUT_REDUCER_OK, outputLength <= capacity else { return nil }
            return try? JSONDecoder().blockingDecode(Response.self, from: Data(output.prefix(outputLength)))
        }
        return nil
    }
}
