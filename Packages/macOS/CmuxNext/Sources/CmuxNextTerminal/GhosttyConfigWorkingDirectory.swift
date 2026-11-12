import Foundation

/// Ghostty's `working-directory` (red stub: not read yet).
public nonisolated enum GhosttyConfigWorkingDirectory: Equatable, Sendable {
    case home
    case inherit
    case path(String)

    static func value(inFiles paths: [String]) -> Self? { nil }
    static func value(configText text: String, after value: Self? = nil) -> Self? { value }
    func start(home: String, isDirectory: (String) -> Bool) -> String? { nil }
}
