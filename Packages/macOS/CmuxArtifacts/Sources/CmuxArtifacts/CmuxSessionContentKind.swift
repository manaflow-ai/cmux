import Foundation

/// Ordinary content directories available beneath one agent-session folder.
enum CmuxSessionContentKind: String, CaseIterable, Sendable {
    case artifacts
    case notes
}
