import CCmuxLayoutReducerFFI
import CmuxNextDesign
import Foundation

/// Marshals every configured pair once on settings reload. Precedence,
/// validation, normalization and bounds remain in Rust's existing reducer.
struct WorkspaceRowLayoutResolver {
    private struct Problem: Decodable, Hashable { var at: String; var why: String; var token: String? }
    private struct Reply: Decodable {
        var problems: [Problem]
        var layout: WorkspaceRowLayout

        init(from decoder: any Decoder) throws {
            layout = try WorkspaceRowLayout(from: decoder)
            let container = try decoder.container(keyedBy: CodingKeys.self)
            problems = try container.decode([Problem].self, forKey: .problems)
        }
        private enum CodingKeys: String, CodingKey { case problems }
    }

    func parse(_ root: JSONValue, diagnostics: inout [SettingsDiagnostic]) -> WorkspaceRowLayouts {
        let keys = ["lines", "linesByKind", "linesByAgent"]
        let fields = Dictionary(uniqueKeysWithValues: keys.map { key in
            (key, root["sidebar.workspaceRow.\(key)"] ?? root.value(at: WorkspaceRowSetting.root + [key]) ?? .null)
        })
        guard fields.values.contains(where: { !$0.isNull }) else { return WorkspaceRowLayouts() }
        let agents: [String]
        if case .object(let map)? = fields["linesByAgent"] { agents = map.keys.sorted() } else { agents = [] }
        var kinds: [WorkspaceRowKind: WorkspaceRowLayouts.Kind] = [:]
        var elements: Set<WorkspaceRowElement> = []
        var seen: Set<Problem> = []
        for kind in WorkspaceRowKind.allCases {
            var entry = WorkspaceRowLayouts.Kind()
            for agent in [nil] + agents.map(Optional.some) {
                var request = fields
                // Send only this pair's entries, not every agent map once per pair.
                request["linesByKind"] = selected(fields["linesByKind"], key: kind.rawValue)
                request["linesByAgent"] = selected(fields["linesByAgent"], key: agent)
                request["kind"] = .string(kind.rawValue)
                request["agent"] = agent.map(JSONValue.string) ?? .null
                guard let data = try? JSONEncoder().encode(JSONValue.object(request)), let reply = call(data) else {
                    diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: "sidebar.workspaceRow.lines",
                                                          message: "sidebar row layout resolver is unavailable"))
                    return WorkspaceRowLayouts()
                }
                for problem in reply.problems where seen.insert(problem).inserted {
                    diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: problem.at,
                                                          message: "sidebar row layout \(problem.why)"))
                }
                if let agent { entry.agents[agent] = reply.layout } else { entry.fallback = reply.layout }
                if reply.layout.custom {
                    elements.formUnion(reply.layout.lines.flatMap { $0 }.compactMap(WorkspaceRowElement.init(rawValue:)))
                    if reply.layout.slots.icon { elements.insert(.icon) }
                    if reply.layout.slots.working { elements.insert(.working) }
                    if reply.layout.slots.progress { elements.insert(.progress) }
                }
            }
            kinds[kind] = entry
        }
        return WorkspaceRowLayouts(kinds: kinds, elements: elements)
    }

    private func selected(_ value: JSONValue?, key: String?) -> JSONValue {
        guard case .object(let map)? = value else { return value ?? .null }
        guard let key, let entry = map[key] else { return .object([:]) }
        return .object([key: entry])
    }

    private func call(_ data: Data) -> Reply? {
        var capacity = 4096
        for _ in 0..<2 {
            var output = [UInt8](repeating: 0, count: capacity)
            var length = 0
            let code: Int32 = data.withUnsafeBytes { request in
                "sidebar_row_layout".withCString { operation in
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
