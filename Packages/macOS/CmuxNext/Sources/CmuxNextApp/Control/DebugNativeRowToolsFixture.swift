#if DEBUG
import AppKit
import CmuxNextAgentPane
import CmuxNextDesign
import CmuxNextSettings

/// A synthetic native-tools page for capture slots with no chat, worktree or pull request.
/// The provider belongs to one app's page store, and each window gets its own fixture view.
@MainActor
final class DebugNativeRowToolsFixture: InternalPageProvider {
    static let pageID = InternalPageID(rawValue: "native-row-tools-fixture")
    var page: InternalPageID { Self.pageID }
    var title: String { "Native row tools fixture" }
    var symbol: String { "rectangle.topthird.inset.filled" }

    private var views: [String: DebugNativeRowToolsFixtureView] = [:]

    func tabClosed(_ key: String) { views.removeValue(forKey: key) }

    func makeView(for key: String, in window: WindowController?) -> NSView {
        let view = DebugNativeRowToolsFixtureView(frame: .zero)
        views[key] = view
        return view
    }

    /// Uses the page's public request decoder, which calls AgentPaneTabRowTools.list.
    /// Its refusal is `.unsupported`; the fixture never substitutes a permissive decoder.
    static func decode(_ tools: JSONValue) -> [PaneTabRowTool]? {
        let request = AgentPaneRequest(body: ["method": "pane.tabRowTools.set", "params": ["tools": tools.foundationObject]])
        guard case .tabRowToolsSet(let tools) = request else { return nil }
        return tools
    }

    /// `debug.native_row_tools_fixture {tools?, menu?, width?, window?}`; never writes a setting.
    static func show(_ params: [String: JSONValue], services: AppServices) -> JSONValue {
        let windowID = params["window"]?.stringValue
        let controller = services.windows.controllers.first(where: { controller in windowID.map { $0 == controller.state.id } ?? true })
                ?? (windowID == nil ? services.windows.active : nil)
        guard let tools = decode(params["tools"] ?? sample) else {
            let provider = services.pages.provider(pageID) as? DebugNativeRowToolsFixture
            for view in provider?.views.values.filter({ $0.window != nil && $0.window === controller?.window }) ?? [] {
                view.configure(tools: [], width: view.rowWidth)
            }
            return .object(["error": .string("unsupported pane.tabRowTools.set: invalid tools")])
        }
        guard let controller else { return .object(["error": .string("no window")]) }
        let width = params["width"]?.doubleValue ?? 760
        guard width.isFinite, (1...2000).contains(width) else {
            return .object(["error": .string("width must be between 1 and 2000 points")])
        }
        if services.pages.provider(pageID) == nil { services.pages.register(DebugNativeRowToolsFixture()) }
        guard let page = services.pages.show(pageID, in: controller, focus: true),
              let fixture = page.content as? DebugNativeRowToolsFixtureView else {
            return .object(["error": .string("no fixture page")])
        }
        fixture.configure(tools: tools, width: width)
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        if let menu = params["menu"]?.stringValue, !fixture.openMenu(menu) {
            return .object(["error": .string("no visible enabled menu tool: \(menu)")])
        }
        let rect = fixture.toolbar.convert(fixture.toolbar.bounds, to: nil)
        return .object(["ok": .bool(true), "window": .string(controller.state.id),
                        "tools": .array(tools.map { .string($0.id) }),
                        "row": .array([.number(rect.minX), .number(rect.minY), .number(rect.width), .number(rect.height)]),
                        "scale": .number(controller.window?.backingScaleFactor ?? 1)])
    }

    /// Raw page payload, including the text and URL fields introduced by #28566.
    static var sample: JSONValue {
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
