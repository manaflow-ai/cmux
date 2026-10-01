public import Foundation

/// The user's agent pane customization files.
public nonisolated struct AgentPaneCustomization: Equatable, Sendable {
    public var themeCSS: String?
    public var registryJS: String?
    public var layoutJSON: String?

    public init(themeCSS: String? = nil, registryJS: String? = nil, layoutJSON: String? = nil) {
        self.themeCSS = themeCSS
        self.registryJS = registryJS
        self.layoutJSON = layoutJSON
    }

    public init(directory: URL) {
        self.init()
    }

    public var isEmpty: Bool { themeCSS == nil && registryJS == nil && layoutJSON == nil }

    public static func directory(configFile: URL) -> URL { configFile }

    func scripts() -> [String] { [] }
}
