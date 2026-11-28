@_implementationOnly import CCmuxLayoutReducerFFI
import Foundation

enum AgentPaneNewTabPrefetchPlan {
    /// Rust chooses the missing split frames and restores the single renderer's Cmd-T size last.
    static func make(parked: CGSize, splits: [CGSize], cached: [CGSize]) -> [CGSize] {
        struct Size: Codable {
            var width: Double, height: Double
            init(_ size: CGSize) { width = size.width; height = size.height }
            var size: CGSize { CGSize(width: width, height: height) }
        }
        struct Request: Encodable { var parked: Size, splits: [Size], cached: [Size] }
        guard let data = try? JSONEncoder().encode(Request(parked: Size(parked), splits: splits.map(Size.init), cached: cached.map(Size.init))) else { return [] }
        var output = [UInt8](repeating: 0, count: 1024), length = 0
        let code: Int32 = data.withUnsafeBytes { request in
            "new_tab_prefetch".withCString { operation in
                output.withUnsafeMutableBytes { buffer in
                    cmux_layout_reducer_json(request.bindMemory(to: UInt8.self).baseAddress, data.count, operation,
                                             buffer.bindMemory(to: UInt8.self).baseAddress, buffer.count, &length)
                }
            }
        }
        guard code == CMUX_LAYOUT_REDUCER_OK, length <= output.count,
              let sizes = try? JSONDecoder().decode([Size].self, from: Data(output.prefix(length))) else { return [] }
        return sizes.map(\.size)
    }
}
