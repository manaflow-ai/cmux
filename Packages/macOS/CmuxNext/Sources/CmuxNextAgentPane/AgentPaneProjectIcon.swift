import Foundation

/// Not implemented yet: the red regression stub for `project.icon`.
nonisolated struct AgentPaneProjectIcon: Sendable {
    static let maximumBytes = 64 * 1024
    var stat: @Sendable (String) -> Date? = { _ in nil }
    var read: @Sendable (String) -> Data? = { _ in nil }
    init(home: String = NSHomeDirectory()) {}
    static func candidates(in folder: String) -> [String] { [] }
    func icon(in folder: String) -> String? { nil }
}

actor AgentPaneProjectIcons {
    static let shared = AgentPaneProjectIcons(reader: AgentPaneProjectIcon())
    init(reader: AgentPaneProjectIcon) {}
    func icon(for folder: String) -> String? { nil }
}
