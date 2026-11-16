import CCmuxLayoutReducerFFI
import CmuxNextCompat
import CmuxNextDesign
import Foundation

/// The cmux-config bridge for section and workspace projection settings. Rust
/// owns validation and bounds; Swift maps only the normalized result.
enum SidebarProjectionCustomizationResolver {
    private struct Workspace: Decodable {
        var hidden: Bool
        var group: String?
        var order: Int?
    }

    private struct Problem: Decodable { var path: String; var why: String }

    private struct Reply: Decodable {
        var hidden: [String]
        var order: [String]
        var workspaces: [String: Workspace]
        var problems: [Problem]
        var complete: Bool?
    }

    static func parse(_ root: JSONValue, diagnostics: inout [SettingsDiagnostic]) -> SidebarProjectionCustomization {
        let sections = root.value(at: ["sidebar", "sections"]) ?? .null
        let workspaces = root["sidebar.workspaces"] ?? root.value(at: ["sidebar", "workspaces"]) ?? .null
        let request = JSONValue.object(["sections": sections, "workspaces": workspaces])
        guard let data = try? JSONEncoder().encode(request), let reply: Reply = call("sidebar_section_customization", data) else {
            return .defaults
        }
        for problem in reply.problems {
            diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: problem.path,
                                                  message: "sidebar projection \(problem.why)"))
        }
        // A malformed value marks the result incomplete: the sidebar keeps its
        // last good projection (SidebarModel.sectionCustomization) until a
        // saved fix reloads through the watcher.
        return SidebarProjectionCustomization(hiddenSections: reply.hidden, sectionOrder: reply.order,
                                              workspaces: reply.workspaces.mapValues { .init(hidden: $0.hidden, group: $0.group, order: $0.order) },
                                              isComplete: reply.complete ?? reply.problems.isEmpty)
    }

    /// One `cmux_layout_reducer_json` call, retried once with the needed
    /// buffer when the reply is larger than the first.
    static func call<Answer: Decodable>(_ operationName: String, _ data: Data) -> Answer? {
        var capacity = 4096
        for _ in 0..<2 {
            var output = [UInt8](repeating: 0, count: capacity)
            var length = 0
            let code: Int32 = data.withUnsafeBytes { request in
                operationName.withCString { operation in
                    output.withUnsafeMutableBytes { buffer in
                        cmux_layout_reducer_json(request.bindMemory(to: UInt8.self).baseAddress, data.count, operation,
                                                 buffer.bindMemory(to: UInt8.self).baseAddress, buffer.count, &length)
                    }
                }
            }
            if code == -3, length > capacity { capacity = length; continue }
            guard code == 0, length >= 0, length <= capacity else { return nil }
            return try? JSONDecoder().decode(Answer.self, from: Data(output.prefix(length)))
        }
        return nil
    }
}
