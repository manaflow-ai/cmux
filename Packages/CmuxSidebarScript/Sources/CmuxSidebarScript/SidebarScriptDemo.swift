import Foundation

/// Bundled sidebar scripts users can install into `~/.config/cmux/sidebar.lisp`.
public struct SidebarScriptDemo: Identifiable, Equatable {
    public let id: String
    public let resourceName: String
    public let source: String

    public init(id: String, resourceName: String, source: String) {
        self.id = id
        self.resourceName = resourceName
        self.source = source
    }

    public static let all: [SidebarScriptDemo] = [
        SidebarScriptDemo(id: "default", resourceName: "DefaultSidebar", source: SidebarScript.defaultSource()),
        demo(id: "liquid-glass", resourceName: "LiquidGlassSidebar"),
        demo(id: "high-density-ide", resourceName: "HighDensityIDESidebar"),
        demo(id: "terminal-stealth", resourceName: "TerminalStealthSidebar"),
        demo(id: "pro-studio", resourceName: "ProStudioSidebar"),
        demo(id: "finder", resourceName: "FinderSidebar"),
        demo(id: "agent-ops", resourceName: "AgentOpsSidebar"),
    ]

    public static func matchingDemoId(for source: String) -> String? {
        let normalized = normalize(source)
        return all.first { normalize($0.source) == normalized }?.id
    }

    private static func demo(id: String, resourceName: String) -> SidebarScriptDemo {
        SidebarScriptDemo(id: id, resourceName: resourceName, source: source(resourceName: resourceName))
    }

    private static func source(resourceName: String) -> String {
        guard let url = Bundle.module.url(forResource: resourceName, withExtension: "lisp"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            return ""
        }
        return text
    }

    private static func normalize(_ source: String) -> String {
        source.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
