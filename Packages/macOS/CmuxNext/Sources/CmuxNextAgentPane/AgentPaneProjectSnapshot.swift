internal import CCmuxAgentPanePolicyFFI
import Foundation

/// Thin JSON transport to Rust's opening-scoped project snapshot. No disk work
/// or ordering runs when a New Tab paints.
@MainActor enum AgentPaneProjectSnapshot {
    static var cachedProjects: [String] = []
    static var cachedRepos: [String: Any] = [:]

    static func rows(projects: [String], repos: [String: Any], warm: String?, cwd: String?, seed: String? = nil) -> String? {
        var request: [String: Any] = ["projects": projects, "repos": repos]
        request["warm"] = warm
        request["cwd"] = cwd
        request["seed"] = seed
        guard let data = try? JSONSerialization.data(withJSONObject: request) else { return seed }
        var output = CmuxAgentPaneBytes(ptr: nil, len: 0)
        let status = data.withUnsafeBytes { bytes in
            "new_tab_projects".withCString { op in
                cmux_agent_pane_policy_call(nil, op, bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count, &output)
            }
        }
        guard status == 0, let pointer = output.ptr else { return seed }
        defer { cmux_agent_pane_policy_bytes_free(output) }
        let reply = Data(bytes: pointer, count: output.len)
        return ((try? JSONSerialization.jsonObject(with: reply)) as? [String: Any])?["rows"] as? String
    }
}
