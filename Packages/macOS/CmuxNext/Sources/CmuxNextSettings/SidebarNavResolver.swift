import CCmuxLayoutReducerFFI
import CmuxNextCompat
import CmuxNextDesign
import Foundation

/// The cmux-config bridge for `sidebar.nav`. Rust owns the rules (catalog ids, no debug or
/// destructive actions, bounds); Swift maps only the rows it answers.
enum SidebarNavResolver {
    private struct Row: Decodable { var action: String; var title: String?; var symbol: String? }
    private struct Problem: Decodable { var path: String; var why: String }
    private struct Reply: Decodable { var rows: [Row]; var problems: [Problem] }

    static func parse(_ root: JSONValue, diagnostics: inout [SettingsDiagnostic]) -> [SidebarNavRow] {
        guard let nav = root.value(at: SidebarSectionsSetting.navPath) else { return [] }
        guard let data = try? JSONEncoder().encode(JSONValue.object(["nav": nav])), let reply = call(data) else { return [] }
        for problem in reply.problems {
            diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: problem.path, message: problem.why))
        }
        return reply.rows.map { SidebarNavRow(action: $0.action, title: $0.title, symbol: $0.symbol) }
    }

    private static func call(_ data: Data) -> Reply? {
        var capacity = 4096
        for _ in 0..<2 {
            var output = [UInt8](repeating: 0, count: capacity)
            var length = 0
            let code: Int32 = data.withUnsafeBytes { request in
                "sidebar_nav".withCString { operation in
                    output.withUnsafeMutableBytes { buffer in
                        cmux_layout_reducer_json(request.bindMemory(to: UInt8.self).baseAddress, data.count, operation,
                                                 buffer.bindMemory(to: UInt8.self).baseAddress, buffer.count, &length)
                    }
                }
            }
            if code == -3, length > capacity { capacity = length; continue }
            guard code == 0, length >= 0, length <= capacity else { return nil }
            return try? JSONDecoder().decode(Reply.self, from: Data(output.prefix(length)))
        }
        return nil
    }
}
