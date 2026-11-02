#if DEBUG
public import CmuxNextDesign
public import CmuxNextSettings

/// Synthetic capture payloads go through the same request decoder as an agent page.
@MainActor
public struct DebugNativeRowToolsSample {
    /// Creates a sample without changing application state or settings.
    public init() {}

    /// Uses the page's public request decoder, which calls AgentPaneTabRowTools.list.
    /// Its refusal is `.unsupported`; the fixture never substitutes a permissive decoder.
    public func decode(_ tools: JSONValue) -> [PaneTabRowTool]? {
        let request = AgentPaneRequest(body: ["method": "pane.tabRowTools.set", "params": ["tools": tools.foundationObject]])
        guard case .tabRowToolsSet(let tools) = request else { return nil }
        return tools
    }

    /// Raw page payload, including the text and URL fields introduced by #28566.
    public var tools: JSONValue {
        func row(_ id: String, _ label: String, enabled: Bool = true, url: String? = nil) -> JSONValue {
            var row: [String: JSONValue] = ["id": .string(id), "label": .string(label), "enabled": .bool(enabled)]
            if let url { row["url"] = .string(url) }
            return .object(row)
        }
        func tool(_ id: String, _ symbol: String, _ label: String, text: String? = nil,
                  toggled: Bool = false, menu: [JSONValue] = []) -> JSONValue {
            var tool: [String: JSONValue] = ["id": .string(id), "symbol": .string(symbol), "label": .string(label),
                                           "enabled": .bool(true), "toggled": .bool(toggled), "menu": .array(menu)]
            if let text { tool["text"] = .string(text) }
            return .object(tool)
        }
        return .array([
            tool("project", "folder", "Project"), tool("terminal", "terminal", "Terminal"),
            tool("files", "doc", "Files"), tool("preview", "eye", "Preview"),
            tool("worktree", "arrow.triangle.branch", "Worktree", text: "fix-login", menu: [
                row("branch", "Branch: fix-login", enabled: false), row("base", "Base: main", enabled: false),
                row("apply", "Apply"), row("remove", "Remove"),
            ]),
            tool("pr", "arrow.triangle.pull", "Pull request", text: "#123 ✓3/5", menu: [
                row("open", "Open #123", url: "https://example.com/pull/123"),
                row("passing", "✓ Tests passing", url: "https://example.com/checks/1"),
                row("failing", "✕ Lint failing", url: "https://example.com/checks/2"),
                row("pending", "Build pending", enabled: false), row("merge", "Merge"),
            ]),
            tool("session-info", "info.circle", "Session Info", toggled: true),
        ])
    }
}
#endif
